// MeetingsViewModel.swift — состояние раздела «Встречи» (задача 06):
// запись + список прошлых записей + плеер.
//
// Владеет RecordingSession (создаёт на старте записи), списком записей
// (скан <vault>/Meetings/_recordings/: sidecar-метаданные + файлы-сироты)
// и одним AVPlayer на раздел. Разрешение на микрофон запрашивается перед
// стартом; статусы разрешений опубликованы для UI. При открытии раздела и
// смене vault подхватывает осиротевшие .caf после краша (recoverOrphans).
//
// Пайплайн встречи (транскрипция → summary → заметка) появится в задаче 11
// и будет строиться поверх этого VM.

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

    /// Поддерживает ли эта macOS запись системного звука (process tap, 14.4+).
    nonisolated static var systemAudioSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    private let vaultManager: VaultManager
    private var player: AVPlayer?
    private var playbackObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    init(vaultManager: VaultManager) {
        self.vaultManager = vaultManager
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
            _ = try await session.stop()
        } catch {
            lastError = normalize(error)
        }
        self.session = nil
        refresh()
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
