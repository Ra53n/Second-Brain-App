// MeetingsViewModel.swift — состояние раздела «Встречи» (задачи 06 + 11):
// запись, список записей с плеером и пайплайн «запись → заметка».
//
// Владеет RecordingSession (создаёт на старте записи), списком записей
// (скан <vault>/Meetings/_recordings/: sidecar-метаданные + файлы-сироты),
// одним AVPlayer на раздел, MeetingStore + MeetingPipeline (задача 11).
// Разрешение на микрофон запрашивается перед стартом; статусы разрешений
// опубликованы для UI. При открытии раздела и смене vault подхватывает
// осиротевшие .caf после краша (recoverOrphans).
//
// Поле «название встречи» заполняется ДО записи — тогда пайплайн после
// summary идёт в filing без диалога подтверждения.

import AVFoundation
import Combine
import Foundation

@MainActor
final class MeetingsViewModel: ObservableObject {

    /// Строка списка прошлых записей: одна запись = один sidecar
    /// (или файл-сирота без метаданных).
    struct RecordingItem: Identifiable, Equatable {
        let id: String
        let playbackURL: URL          // основная дорожка для плеера
        let title: String             // базовое имя записи
        let date: Date?
        let duration: TimeInterval?
        let source: RecordingSource?
        let trackCount: Int           // 1 или 2 дорожки
    }

    @Published var sourceChoice: RecordingSource = .microphone
    @Published private(set) var session: RecordingSession?
    @Published private(set) var recordings: [RecordingItem] = []
    @Published var lastError: AudioRecordingError?
    /// nil — разрешение ещё не запрашивалось (покажем «спросим при записи»).
    @Published private(set) var micAuthorized: Bool?
    @Published private(set) var playingURL: URL?

    // --- пайплайн встречи (задача 11) ---
    /// Название встречи, заданное ДО записи: пайплайн минует диалог подтверждения.
    @Published var presetTitle: String = ""
    /// Контекст, ждущий подтверждения названия/папки (открывает sheet).
    @Published var titleDialog: MeetingContext?
    @Published var pipelineError: String?
    /// Правила раскладки для LLM (редактируются в разделе, [USER_RULES] промпта).
    @Published var filingRules: String {
        didSet {
            guard filingRules != oldValue else { return }
            var settings = MeetingSettings()
            settings.filingRules = filingRules
            MeetingSettingsStore.save(settings)
        }
    }
    let meetingStore: MeetingStore
    private(set) var pipeline: MeetingPipeline!

    /// Поддерживает ли эта macOS запись системного звука (process tap, 14.4+).
    nonisolated static var systemAudioSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    private let vaultManager: VaultManager
    private var player: AVPlayer?
    private var playbackObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    init(vaultManager: VaultManager, functionRouter: FunctionRouter) {
        self.vaultManager = vaultManager
        self.meetingStore = MeetingStore()
        self.filingRules = MeetingSettingsStore.load().filingRules
        self.pipeline = MeetingPipeline(
            router: functionRouter,
            store: meetingStore,
            vaultURL: { [weak vaultManager] in vaultManager?.vaultURL },
            vaultFolders: { [weak vaultManager] in
                guard let manager = vaultManager,
                      let vault = manager.vaultURL,
                      let root = manager.root else { return [] }
                // Относительные пути папок vault для промпта и валидации.
                let prefix = vault.path.hasSuffix("/") ? vault.path : vault.path + "/"
                return root.allFolders
                    .map { $0.url.path }
                    .compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
                    .filter { !$0.isEmpty }
            })
        // Статус без промпта: notDetermined оставляем nil («спросим при записи»).
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micAuthorized = true
        case .denied, .restricted: micAuthorized = false
        default: micAuthorized = nil
        }
        // Список записей зависит от vault — обновляем при открытии/смене.
        vaultManager.$vaultURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadAfterVaultChange() }
            .store(in: &cancellables)
    }

    /// Папка записей текущего vault (nil — vault не открыт).
    var recordingsDirectory: URL? {
        vaultManager.vaultURL?.appendingPathComponent("Meetings/_recordings", isDirectory: true)
    }

    var isRecordingActive: Bool {
        guard let session else { return false }
        return session.state == .recording || session.state == .paused
    }

    // MARK: - Запись

    func startRecording() async {
        guard !isRecordingActive else { return }
        guard let directory = recordingsDirectory else {
            lastError = .noVault
            return
        }
        if sourceChoice.needsMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micAuthorized = granted
            guard granted else {
                lastError = .microphonePermissionDenied
                return
            }
        }
        if sourceChoice.needsSystemAudio, !Self.systemAudioSupported {
            lastError = .systemAudioUnsupported
            return
        }
        let newSession = RecordingSession(source: sourceChoice, directory: directory)
        do {
            try newSession.start()
            stopPlayback() // не играем поверх записи
            session = newSession
        } catch {
            lastError = normalize(error)
        }
    }

    func togglePause() {
        guard let session else { return }
        do {
            if session.state == .recording {
                try session.pause()
            } else if session.state == .paused {
                try session.resume()
            }
        } catch {
            lastError = normalize(error)
        }
    }

    func stopRecording() async {
        guard let session else { return }
        do {
            let result = try await session.stop()
            // Название задано до записи — сразу заводим контекст встречи:
            // пайплайн потом пройдёт мимо диалога подтверждения (задача 11).
            let preset = presetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preset.isEmpty, let base = session.currentBaseName {
                meetingStore.upsert(MeetingContext(
                    recordingBase: base,
                    audioFiles: result.metadata.files,
                    recordedAt: result.metadata.date,
                    duration: result.metadata.duration,
                    presetTitle: preset))
                presetTitle = ""
            }
        } catch {
            lastError = normalize(error)
        }
        self.session = nil
        refresh()
    }

    // MARK: - Пайплайн встречи (задача 11)

    /// Контекст встречи для строки списка (nil — пайплайн не запускался).
    func meeting(for item: RecordingItem) -> MeetingContext? {
        meetingStore.context(forRecordingBase: item.id)
    }

    /// Кнопка «Транскрибировать»/«Продолжить»/«Повторить»: создаёт контекст
    /// при необходимости и (воз)обновляет прогон.
    func runPipeline(for item: RecordingItem) {
        let context: MeetingContext
        if let existing = meeting(for: item) {
            context = existing
        } else {
            context = MeetingContext(
                recordingBase: item.id,
                audioFiles: trackFileNames(for: item),
                recordedAt: item.date ?? .distantPast,
                duration: item.duration ?? 0,
                presetTitle: nil)
            meetingStore.upsert(context)
        }
        Task { [weak self] in
            await self?.pipeline.run(context.id)
            self?.presentTitleDialogIfNeeded(context.id)
        }
    }

    /// Подтверждение из диалога названия/папки.
    func confirmTitle(_ title: String, folder: String) {
        guard let context = titleDialog else { return }
        titleDialog = nil
        Task { [weak self] in
            await self?.pipeline.confirmTitle(context.id, title: title, folder: folder)
        }
    }

    /// Открывает диалог, если прогон дошёл до awaitingTitle (в т.ч. после рестарта).
    func presentTitleDialogIfNeeded(_ id: UUID) {
        guard let context = meetingStore.context(id: id) else { return }
        if context.state == .awaitingTitle {
            titleDialog = context
        } else if context.status == .failed {
            pipelineError = context.errorText
        }
    }

    /// Заметка встречи открывается в разделе «Заметки».
    func openNote(_ context: MeetingContext) {
        guard let vault = vaultManager.vaultURL, let path = context.notePath else { return }
        NotificationCenter.default.post(name: .openNoteInEditor,
                                        object: vault.appendingPathComponent(path))
    }

    /// Имена всех дорожек записи (из sidecar; сирота — единственный файл).
    private func trackFileNames(for item: RecordingItem) -> [String] {
        guard let directory = recordingsDirectory else { return [item.playbackURL.lastPathComponent] }
        let sidecar = RecordingMetadataStore.sidecarURL(base: item.id, in: directory)
        if let metadata = try? RecordingMetadataStore.load(from: sidecar), !metadata.files.isEmpty {
            return metadata.files
        }
        return [item.playbackURL.lastPathComponent]
    }

    // MARK: - Список записей

    /// Вызывается при появлении раздела и смене vault: сперва восстановление
    /// осиротевших .caf (после краша), затем скан папки.
    func reloadAfterVaultChange() {
        refresh()
        guard let directory = recordingsDirectory else { return }
        Task { [weak self] in
            let recovered = await AudioFileConverter.recoverOrphans(in: directory)
            if !recovered.isEmpty { self?.refresh() }
        }
    }

    func refresh() {
        guard let directory = recordingsDirectory else {
            recordings = []
            return
        }
        recordings = Self.scanRecordings(in: directory,
                                         skippingBase: isRecordingActive ? session?.currentBaseName : nil)
    }

    /// Скан папки записей: сперва sidecar'ы (одна запись = один item),
    /// затем аудиофайлы, не упомянутые ни в одном sidecar'е (сироты).
    /// `skippingBase` — базовое имя активной записи: её недописанные файлы не показываем.
    static func scanRecordings(in directory: URL, skippingBase: String? = nil) -> [RecordingItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }

        var items: [RecordingItem] = []
        var referenced: Set<String> = []

        for sidecar in urls where sidecar.pathExtension.lowercased() == "json" {
            let base = sidecar.deletingPathExtension().lastPathComponent
            guard base != skippingBase else { continue }
            guard let metadata = try? RecordingMetadataStore.load(from: sidecar) else { continue }
            referenced.formUnion(metadata.files)
            // Основная дорожка — первый существующий файл из метаданных.
            let existing = metadata.files
                .map { directory.appendingPathComponent($0) }
                .filter { fm.fileExists(atPath: $0.path) }
            guard let primary = existing.first else { continue }
            items.append(RecordingItem(id: base,
                                       playbackURL: primary,
                                       title: base,
                                       date: metadata.date == .distantPast ? nil : metadata.date,
                                       duration: metadata.duration,
                                       source: metadata.source,
                                       trackCount: existing.count))
        }

        let audioExtensions: Set<String> = ["m4a", "caf"]
        for url in urls where audioExtensions.contains(url.pathExtension.lowercased()) {
            let name = url.lastPathComponent
            guard !referenced.contains(name) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            if let skippingBase, stem.hasPrefix(skippingBase) { continue }
            items.append(RecordingItem(id: name,
                                       playbackURL: url,
                                       title: stem,
                                       date: RecordingNamer.date(fromBaseName: stem),
                                       duration: AudioFileConverter.audioDuration(of: url),
                                       source: nil,
                                       trackCount: 1))
        }

        // Новые сверху; имена формата YYYY-MM-DD HH-mm сортируются как строки.
        return items.sorted { $0.title > $1.title }
    }

    // MARK: - Плеер

    func togglePlayback(of item: RecordingItem) {
        if playingURL == item.playbackURL {
            stopPlayback()
            return
        }
        stopPlayback()
        let player = AVPlayer(url: item.playbackURL)
        self.player = player
        playingURL = item.playbackURL
        playbackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopPlayback() }
        }
        player.play()
    }

    func stopPlayback() {
        player?.pause()
        player = nil
        playingURL = nil
        if let observer = playbackObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackObserver = nil
        }
    }

    // MARK: - Внутренности

    private func normalize(_ error: Error) -> AudioRecordingError {
        (error as? AudioRecordingError) ?? .fileWriteFailed(error.localizedDescription)
    }
}

extension Notification.Name {
    /// Открыть заметку в разделе «Заметки»: object — URL файла (ловит ContentView).
    static let openNoteInEditor = Notification.Name("openNoteInEditor")
}
