// CodeReviewRunner.swift — общий раннер code review (задача 37).
//
// Три точки входа делят одну сборку input и один способ прогона:
//  - /review <PR> в чате (ChatViewModel.handleSlashCommand);
//  - пресет-пайплайн с PR-watch (PipelineEngine при preset == .codeReview);
//  - /review local — незакоммиченные изменения projectRepoPath, без постинга.
// Прогон — полный FSM задачи 35 поверх целевого чата (displayText короткий,
// полный input в AgentTaskContext.task); после успешного терминала итоговое
// сообщение получает маркер reviewTarget → кнопка «Отправить комментарием в
// PR» (постинг только после явного подтверждения — правило бэклога №16;
// автопост включается отдельным полем пайплайна и тоже только после .finished).
//
// Сжатие большого диффа — map БЕЗ reduce: по вызову модели на чанк, конспекты
// склеиваются. Reduce-проход намеренно отсутствует — он усредняет и теряет
// «путь:строка», на которых держится формат замечаний.

import Foundation

@MainActor
final class CodeReviewRunner {
    private let chatViewModel: ChatViewModel
    private let projectToolsProvider: ProjectToolsProvider
    private let client: GitHubClient
    /// Токен читается на каждый вызов (пользователь мог обновить настройки).
    private let tokenProvider: () -> String?
    private let router: FunctionRouter

    init(chatViewModel: ChatViewModel,
         projectToolsProvider: ProjectToolsProvider,
         router: FunctionRouter,
         client: GitHubClient = GitHubClient(),
         tokenProvider: @escaping () -> String? = { KeyStore.key(for: PRWatcher.githubTokenID) }) {
        self.chatViewModel = chatViewModel
        self.projectToolsProvider = projectToolsProvider
        self.router = router
        self.client = client
        self.tokenProvider = tokenProvider
    }

    /// Есть ли GitHub-токен (для disabled-состояния кнопки отправки).
    var hasToken: Bool {
        !(tokenProvider() ?? "").isEmpty
    }

    // MARK: - Подготовка input

    /// Готовый вход прогона: полный task, короткий display и адрес PR
    /// (nil — локальное ревью, постить некуда).
    struct PreparedReview {
        var task: String
        var display: String
        var target: ReviewTarget?
    }

    enum ReviewError: LocalizedError {
        case repositoryNotConfigured
        case emptyLocalDiff
        case payloadWithoutPR

        var errorDescription: String? {
            switch self {
            case .repositoryNotConfigured:
                return "Репозиторий проекта не выбран: Настройки → «Инструменты»."
            case .emptyLocalDiff:
                return "Незакоммиченных изменений нет — ревьюить нечего."
            case .payloadWithoutPR:
                return "В payload триггера нет ссылки на PR."
            }
        }
    }

    /// Ревью PR по ссылке (/review <URL | owner/repo#n>): метаданные + diff.
    /// condenseProvider — провайдер map-сжатия большого диффа: та же модель,
    /// что поведёт FSM (override чата/пайплайна); nil — дефолт роутера.
    func prepareInput(reference: PRReference,
                      condenseProvider: ResolvedChatProvider? = nil) async throws -> PreparedReview {
        let token = tokenProvider()
        let pr = try await client.pullRequest(owner: reference.owner,
                                              repo: reference.repo,
                                              number: reference.number,
                                              token: token)
        let diff = try await client.diff(owner: reference.owner,
                                         repo: reference.repo,
                                         number: reference.number,
                                         token: token)
        return await assemble(prSummary: pr.payloadText,
                              prTitle: pr.title,
                              diff: diff,
                              target: reference,
                              condenseProvider: condenseProvider)
    }

    /// Ревью из PR-watch: payload уже содержит метаданные и diff_url —
    /// отдельный запрос метаданных не нужен (подсказка задачи).
    func prepareInput(prWatchPayload payload: String,
                      condenseProvider: ResolvedChatProvider? = nil) async throws -> PreparedReview {
        guard let reference = PRReference.firstMatch(in: payload) else {
            throw ReviewError.payloadWithoutPR
        }
        let token = tokenProvider()
        // diff_url — строка «diff: …» payload'а; надёжнее собрать по номеру.
        let diff = try await client.diff(owner: reference.owner,
                                         repo: reference.repo,
                                         number: reference.number,
                                         token: token)
        let title = payload.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? "PR #\(reference.number)"
        return await assemble(prSummary: payload,
                              prTitle: title,
                              diff: diff,
                              target: reference,
                              condenseProvider: condenseProvider)
    }

    /// Локальное ревью незакоммиченных изменений projectRepoPath. Диф — через
    /// GitClient напрямую (без 64 КБ-капа инструмента git_diff: кап и
    /// чанкование у ревью свои).
    func prepareLocalInput(condenseProvider: ResolvedChatProvider? = nil) async throws -> PreparedReview {
        guard let root = projectToolsProvider.currentRepoRoot() else {
            throw ReviewError.repositoryNotConfigured
        }
        let diff = try await GitClient(repoURL: root).diff()
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReviewError.emptyLocalDiff
        }
        return await assemble(prSummary: nil,
                              prTitle: "локальные изменения \(root.lastPathComponent)",
                              diff: diff,
                              target: nil,
                              condenseProvider: condenseProvider)
    }

    // MARK: - Прогон и постинг

    /// FSM-прогон в чат по индексу; после успешного терминала итоговое
    /// сообщение маркируется reviewTarget (если есть куда постить).
    @discardableResult
    func runReview(prepared: PreparedReview, chatIndex: Int) async -> AgentRunStatus {
        let chatID = chatViewModel.chats[chatIndex].id
        let status = await chatViewModel.runAgentToCompletion(
            chatIndex: chatIndex,
            userText: prepared.task,
            displayText: prepared.display)
        if status == .finished, let target = prepared.target {
            markResultMessage(chatID: chatID, target: target)
        }
        return status
    }

    /// Комментарий в PR. Успех отмечает сообщение reviewPostedAt («Отправлено ✓»).
    func post(target: ReviewTarget, body: String, messageID: UUID?) async throws {
        try await client.postComment(owner: target.owner, repo: target.repo,
                                     number: target.number, body: body,
                                     token: tokenProvider())
        if let messageID {
            markPosted(messageID: messageID)
        }
    }

    /// Автопост пресета: строго после успешного терминала (вызывается движком
    /// только в ветке .finished), постится content итогового сообщения.
    /// Ошибка не роняет прогон — возвращается текстом для errorText.
    func autoPostIfConfigured(chatID: UUID, messageID: UUID?) async -> String? {
        guard let messageID,
              let chat = chatViewModel.chats.first(where: { $0.id == chatID }),
              let message = chat.messages.first(where: { $0.id == messageID }),
              let target = message.reviewTarget else { return nil }
        do {
            try await post(target: target, body: message.content, messageID: messageID)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Внутренности

    /// Общая часть: condense большого диффа, доки, тесты, сборка секций.
    private func assemble(prSummary: String?, prTitle: String,
                          diff: String, target: ReviewTarget?,
                          condenseProvider: ResolvedChatProvider?) async -> PreparedReview {
        let files = CodeReviewInput.splitByFile(diff)
        let diffSection = await condenseIfNeeded(diff: diff, files: files,
                                                 preferred: condenseProvider)
        let docs = await projectToolsProvider.helpContext(question: "code review: \(prTitle)")
        let tests = await testsSection(files: files)
        let input = CodeReviewInput.assemble(pr: prSummary,
                                             diff: diffSection,
                                             docs: docs,
                                             tests: tests)
        let display = target.map { "Ревью PR #\($0.number): \(prTitle)" }
            ?? "Ревью: \(prTitle)"
        return PreparedReview(task: CodeReviewPrompts.reviewTask(assembledInput: input),
                              display: display,
                              target: target)
    }

    /// Map-сжатие диффа сверх лимита; в пределах лимита — как есть, 0 вызовов.
    /// preferred — override чата/пайплайна (фидбек пользователя: сжатие должно
    /// идти той же моделью, что и ревью, а не дефолтом роутера).
    private func condenseIfNeeded(diff: String, files: [CodeReviewInput.FileDiff],
                                  preferred: ResolvedChatProvider?) async -> String {
        guard diff.count > CodeReviewInput.maxDiffChars else { return diff }
        guard let resolved = preferred ?? router.resolveChatProvider(for: .chat) else {
            // Провайдера нет — прогон всё равно упадёт с понятной ошибкой
            // на старте FSM; отдаём жёстко обрезанный diff, не теряя запуск.
            return String(diff.prefix(CodeReviewInput.maxDiffChars))
                + "\n…(diff обрезан: провайдер для сжатия недоступен)"
        }
        let chunks = CodeReviewInput.packChunks(files)
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            do {
                let result = try await resolved.provider.send(
                    [ChatMessageDTO(role: .user,
                                    content: CodeReviewPrompts.condensePrompt(
                                        chunk: chunk, index: index, total: chunks.count))],
                    settings: ChatSettings(model: resolved.model))
                partials.append(result.text)
            } catch {
                // Неудачный чанк — честная пометка вместо тихой потери файлов.
                partials.append("…(часть \(index + 1)/\(chunks.count) не сжата: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))")
            }
        }
        var condensed = "Сжатое изложение diff (\(files.count) файлов, "
            + "исходный размер \(diff.count) символов):\n\n"
            + partials.joined(separator: "\n\n")
        if condensed.count > CodeReviewInput.maxCondensedChars {
            condensed = String(condensed.prefix(CodeReviewInput.maxCondensedChars))
                + "\n…(изложение обрезано)"
        }
        return condensed
    }

    /// Секция [TESTS] по путям из диффа и tracked-файлам локального репо.
    /// Репозиторий не настроен → nil (секция опускается; эвристика осмысленна,
    /// когда projectRepoPath указывает на репозиторий ревьюируемого кода).
    private func testsSection(files: [CodeReviewInput.FileDiff]) async -> String? {
        guard let root = projectToolsProvider.currentRepoRoot() else { return nil }
        let tracked = (try? await GitClient(repoURL: root).trackedFiles()) ?? []
        return CodeReviewInput.testsSection(changedPaths: files.map(\.path),
                                            trackedFiles: tracked)
    }

    /// Маркирует итоговое (последнее assistant) сообщение прогона.
    private func markResultMessage(chatID: UUID, target: ReviewTarget) {
        guard let chatIndex = chatViewModel.chats.firstIndex(where: { $0.id == chatID }),
              let messageIndex = chatViewModel.chats[chatIndex].messages
                  .lastIndex(where: { $0.role == .assistant })
        else { return }
        chatViewModel.chats[chatIndex].messages[messageIndex].reviewTarget = target
        chatViewModel.persistNow()
    }

    private func markPosted(messageID: UUID) {
        for chatIndex in chatViewModel.chats.indices {
            if let messageIndex = chatViewModel.chats[chatIndex].messages
                .firstIndex(where: { $0.id == messageID }) {
                chatViewModel.chats[chatIndex].messages[messageIndex].reviewPostedAt = Date()
                chatViewModel.persistNow()
                return
            }
        }
    }
}
