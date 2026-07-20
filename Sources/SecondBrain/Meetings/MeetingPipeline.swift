// MeetingPipeline.swift — оркестрация пайплайна встречи (задача 11).
//
// run(id:) идемпотентен: смотрит текущий state контекста и выполняет следующий
// шаг, в цикле до терминала/ожидания пользователя. После каждого перехода —
// persistNow() (crash-safety: рестарт продолжает с того же места, зависший
// running нормализуется в paused при загрузке MeetingStore).
//
// Провайдеры берутся из FunctionRouter: транскрипция — функция .transcription,
// summary — .meetingSummary (capability .chat). Сбой шага ретраится до
// MeetingContext.maxStepRetries, затем state → .failed (кнопка «Повторить»).
//
// Зависимости vault инжектируются замыканиями (vaultURL, дерево папок) — в
// тестах пайплайн гоняется против временной папки без VaultManager.

import Foundation

@MainActor
final class MeetingPipeline {
    private let router: FunctionRouter
    private let store: MeetingStore
    private let vaultURL: () -> URL?
    private let vaultFolders: () -> [String]      // относительные пути папок vault
    private let settings: () -> MeetingSettings
    /// Живые прогоны, чтобы одна встреча не выполнялась дважды параллельно.
    private var runningIDs: Set<UUID> = []

    init(router: FunctionRouter,
         store: MeetingStore,
         vaultURL: @escaping () -> URL?,
         vaultFolders: @escaping () -> [String],
         settings: @escaping () -> MeetingSettings = { MeetingSettingsStore.load() }) {
        self.router = router
        self.store = store
        self.vaultURL = vaultURL
        self.vaultFolders = vaultFolders
        self.settings = settings
    }

    // MARK: - Публичный API

    /// Запуск/возобновление пайплайна. Идемпототентно продолжает с текущего
    /// этапа; из failed сначала возвращается в упавший этап.
    func run(_ id: UUID) async {
        guard !runningIDs.contains(id) else { return } // уже бежит
        runningIDs.insert(id)
        defer { runningIDs.remove(id) }

        // Ретрай из failed: возвращаемся в упавший этап (переход разрешён таблицей).
        if let context = store.context(id: id), context.state == .failed {
            let target = context.failedStage ?? .transcribing
            store.mutate(id: id) {
                $0 = $0.transitioned(to: target)
                $0.status = .running
                $0.stepRetries = 0
                $0.errorText = nil
            }
        }

        while let context = store.context(id: id) {
            switch context.state {
            case .recorded:
                store.mutate(id: id) {
                    $0 = $0.transitioned(to: .transcribing)
                    $0.status = .running
                }

            case .transcribing:
                guard await attempt(id, stage: .transcribing, step: transcribeStep) else { return }
                store.mutate(id: id) { $0 = $0.transitioned(to: .transcribed) }

            case .transcribed:
                store.mutate(id: id) {
                    $0 = $0.transitioned(to: .summarizing)
                    $0.status = .running
                }

            case .summarizing:
                guard await attempt(id, stage: .summarizing, step: summarizeStep) else { return }
                guard let updated = store.context(id: id) else { return }
                if let preset = updated.presetTitle, !preset.isEmpty {
                    // Название задано до записи — в раскладку без остановки.
                    store.mutate(id: id) { $0 = $0.transitioned(to: .filing) }
                } else {
                    store.mutate(id: id) {
                        $0 = $0.transitioned(to: .awaitingTitle)
                        $0.status = .awaitingUser
                    }
                    return // ждём подтверждения пользователя
                }

            case .awaitingTitle:
                return // выход: продолжение — через confirmTitle

            case .filing:
                guard await attempt(id, stage: .filing, step: fileStep) else { return }
                store.mutate(id: id) {
                    $0 = $0.transitioned(to: .done)
                    $0.status = .finished
                }

            case .done, .failed:
                return
            }
        }
    }

    /// Подтверждение названия/папки из диалога — продолжает пайплайн в filing.
    func confirmTitle(_ id: UUID, title: String, folder: String) async {
        guard let context = store.context(id: id), context.state == .awaitingTitle else { return }
        store.mutate(id: id) {
            $0.confirmedTitle = MeetingNoteWriter.sanitizeTitle(title)
            $0.confirmedFolder = folder.trimmingCharacters(
                in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/")))
            $0 = $0.transitioned(to: .filing)
            $0.status = .running
        }
        await run(id)
    }

    // MARK: - Шаги

    /// Выполняет шаг с ретраями. false — прогон остановлен (failed), цикл run
    /// должен выйти. Сам шаг НЕ меняет state — только артефакты контекста.
    private func attempt(_ id: UUID,
                         stage: MeetingState,
                         step: (MeetingContext) async throws -> Void) async -> Bool {
        while let context = store.context(id: id) {
            do {
                try await step(context)
                store.mutate(id: id) { $0.stepRetries = 0 }
                return true
            } catch {
                let retries = (store.context(id: id)?.stepRetries ?? 0) + 1
                if retries <= MeetingContext.maxStepRetries {
                    store.mutate(id: id) { $0.stepRetries = retries }
                    continue // повторяем шаг
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                store.mutate(id: id) {
                    $0 = $0.transitioned(to: .failed)
                    $0.status = .failed
                    $0.failedStage = stage
                    $0.errorText = message
                }
                return false
            }
        }
        return false
    }

    /// Транскрипция всех дорожек записи выбранным роутером провайдером.
    private func transcribeStep(_ context: MeetingContext) async throws {
        guard let vault = vaultURL() else { throw MeetingError.noVault }
        guard let resolved = router.resolveTranscriptionProvider(for: .transcription) else {
            throw MeetingError.noTranscriptionProvider
        }
        let directory = vault.appendingPathComponent("Meetings/_recordings", isDirectory: true)
        var tracks: [TrackTranscript] = []
        for fileName in context.audioFiles {
            let url = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MeetingError.audioFileMissing(fileName)
            }
            // Облачные STT не принимают внутренний CAF (сирота после краха или
            // сбоя перепаковки на stop()) — нормализуем во временный .m4a.
            // Штатные .m4a уходят как есть.
            let audioURL: URL
            let tempURL: URL?
            if AudioMIME.isCloudSTTReady(url) {
                audioURL = url
                tempURL = nil
            } else {
                let temp = try await AudioFileConverter.temporaryM4A(from: url)
                audioURL = temp
                tempURL = temp
            }
            defer { if let tempURL { try? FileManager.default.removeItem(at: tempURL) } }
            let transcript = try await resolved.provider.transcribe(
                audioURL: audioURL, language: "ru", hints: nil)
            tracks.append(TrackTranscript(fileName: fileName, transcript: transcript))
        }
        guard tracks.contains(where: {
            !$0.transcript.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw MeetingError.emptyTranscript
        }
        let providerID = assignedProviderID(for: .transcription)
        store.mutate(id: context.id) {
            $0.transcripts = tracks
            $0.transcriptionProviderID = providerID
        }
    }

    /// Summary + предложение названия/папки; длинный транскрипт — map-reduce.
    private func summarizeStep(_ context: MeetingContext) async throws {
        guard let resolved = router.resolveChatProvider(for: .meetingSummary) else {
            throw MeetingError.noChatProvider
        }
        let fullText = context.combinedTranscriptText
        let chunks = MeetingPrompts.chunkTranscript(fullText)
        let transcriptForPrompt: String
        if chunks.count <= 1 {
            transcriptForPrompt = fullText
        } else {
            // Map-фаза: промежуточные конспекты чанков.
            var partials: [String] = []
            for (index, chunk) in chunks.enumerated() {
                let result = try await resolved.provider.send(
                    [ChatMessageDTO(role: .user,
                                    content: MeetingPrompts.chunkPrompt(
                                        chunk: chunk, index: index, total: chunks.count))],
                    settings: ChatSettings(model: resolved.model))
                partials.append(result.text)
            }
            transcriptForPrompt = partials.joined(separator: "\n\n")
        }

        let messages = [
            ChatMessageDTO(role: .system, content: MeetingPrompts.systemPrompt()),
            ChatMessageDTO(role: .user, content: MeetingPrompts.buildPrompt(
                transcript: transcriptForPrompt,
                vaultFolders: vaultFolders(),
                userRules: settings().filingRules,
                presetTitle: context.presetTitle))
        ]
        let result = try await resolved.provider.send(
            messages, settings: ChatSettings(model: resolved.model))
        let parsed = MeetingPrompts.parseSummaryResponse(result.text)
        // Папку LLM валидируем против реального дерева vault (фолбэк —
        // папка по умолчанию из настроек либо штатная Meetings/YYYY-MM).
        let (folder, wasInvalid) = MeetingNoteWriter.resolveFolder(
            suggested: parsed.folder,
            existingFolders: vaultFolders(),
            date: context.recordedAt,
            customDefault: settings().defaultFolder)
        store.mutate(id: context.id) {
            $0.summary = parsed.summary
            $0.suggestedTitle = parsed.title ?? ""
            $0.suggestedFolder = folder
            $0.folderWasInvalid = wasInvalid
        }
    }

    /// Раскладка: заметка в vault по подтверждённым названию/папке.
    private func fileStep(_ context: MeetingContext) async throws {
        guard let vault = vaultURL() else { throw MeetingError.noVault }
        let title = context.effectiveTitle
        var folder = context.effectiveFolder
        if folder.isEmpty {
            // Пустая папка возможна только у старых прогонов: фолбэк тот же,
            // что при валидации (настройки → штатная).
            let (resolved, _) = MeetingNoteWriter.resolveFolder(
                suggested: nil,
                existingFolders: [],
                date: context.recordedAt,
                customDefault: settings().defaultFolder)
            folder = resolved
        }
        let path = MeetingNoteWriter.notePath(
            folder: folder,
            date: context.recordedAt,
            title: title
        ) { relative in
            FileManager.default.fileExists(atPath: vault.appendingPathComponent(relative).path)
        }
        let content = MeetingNoteWriter.noteContent(context: context)
        try MeetingNoteWriter.write(content: content, relativePath: path, vaultURL: vault)
        store.mutate(id: context.id) { $0.notePath = path }
    }

    /// ID провайдера, реально выбранного роутером для функции (для frontmatter).
    private func assignedProviderID(for function: AppFunction) -> String? {
        if let assignment = router.assignment(for: function),
           router.registry.isAvailable(assignment.providerID) {
            return assignment.providerID.rawValue
        }
        return router.registry.descriptors(supporting: function.requiredCapability)
            .first { router.registry.isAvailable($0.id) && $0.defaultModel != nil }?
            .id.rawValue
    }
}
