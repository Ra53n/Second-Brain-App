// RecordingSession.swift — FSM одной сессии записи встречи.
//
// Состояния: idle → recording ⇄ paused → stopped; недопустимые переходы бросают
// AudioRecordingError.invalidTransition (guarded transitions, как в FSM MA).
// Сессия владеет дорожками через протокол AudioTrackRecorder (в тестах — моки),
// считает чистую длительность (паузы исключены; часы инжектируются), а при
// остановке перепаковывает CAF → .m4a и пишет sidecar-метаданные.
//
// Crash-safety: дорожки стримятся на диск в CAF — после kill -9 читаемо всё,
// что успело записаться; недоделанный .caf подберёт recoverOrphans() при
// следующем запуске (вызывается из MeetingsViewModel). Если конвертация на
// stop() упала, поведение то же: .caf остаётся, восстановится позже.

import Foundation
import Combine

@MainActor
final class RecordingSession: ObservableObject {

    /// Итог штатной остановки.
    struct Result: Equatable {
        let audioFiles: [URL]        // 1 или 2 дорожки (.m4a)
        let sidecarURL: URL
        let metadata: RecordingMetadata
    }

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsed: TimeInterval = 0 // для таймера в UI (обновляет Timer)
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0

    let source: RecordingSource
    /// Базовое имя файлов записи; известно после start(). Нужно UI,
    /// чтобы не показывать в списке недописанные файлы активной записи.
    private(set) var currentBaseName: String?

    private let directory: URL
    private let micFactory: () throws -> AudioTrackRecorder
    private let systemFactory: () throws -> AudioTrackRecorder
    private let convert: (URL) async throws -> URL
    /// Пустая ли дорожка (не записалось ни одного сэмпла). Инжектируется в
    /// тестах; в проде — нулевая длительность файла. Микрофон без разрешения
    /// или молчащий вход пишет валидный, но пустой CAF: его remux в .m4a падает
    /// и — если не отсеять — роняет весь stop(), теряя вторую (валидную) дорожку.
    private let trackIsEmpty: (URL) -> Bool
    private let clock: () -> TimeInterval  // монотонные часы (инжектируются в тестах)
    private let dateProvider: () -> Date

    private var micRecorder: AudioTrackRecorder?
    private var systemRecorder: AudioTrackRecorder?
    private var trackURLs: [URL] = []             // .caf-файлы дорожек (для подчистки при сбое)
    private var startedAt = Date()
    private var accumulated: TimeInterval = 0     // сумма завершённых отрезков записи
    private var segmentStart: TimeInterval?       // clock() на старте текущего отрезка
    private var timer: Timer?

    init(source: RecordingSource,
         directory: URL,
         micFactory: @escaping () throws -> AudioTrackRecorder,
         systemFactory: @escaping () throws -> AudioTrackRecorder,
         convert: @escaping (URL) async throws -> URL = { try await AudioFileConverter.remuxToM4A($0) },
         trackIsEmpty: @escaping (URL) -> Bool = { AudioFileConverter.audioDuration(of: $0) <= 0 },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         dateProvider: @escaping () -> Date = Date.init) {
        self.source = source
        self.directory = directory
        self.micFactory = micFactory
        self.systemFactory = systemFactory
        self.convert = convert
        self.trackIsEmpty = trackIsEmpty
        self.clock = clock
        self.dateProvider = dateProvider
    }

    /// Продакшн-вариант: реальные рекордеры под выбранный источник.
    convenience init(source: RecordingSource, directory: URL) {
        self.init(source: source,
                  directory: directory,
                  micFactory: { MicrophoneRecorder() },
                  systemFactory: {
                      guard #available(macOS 14.4, *) else {
                          throw AudioRecordingError.systemAudioUnsupported
                      }
                      return SystemAudioRecorder()
                  })
    }

    /// Чистая длительность записи на текущий момент (без пауз).
    var duration: TimeInterval {
        accumulated + (segmentStart.map { clock() - $0 } ?? 0)
    }

    func start() throws {
        guard state == .idle else {
            throw AudioRecordingError.invalidTransition(from: state, action: "start")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        startedAt = dateProvider()
        let base = uniqueBaseName(for: startedAt)
        currentBaseName = base

        var started: [AudioTrackRecorder] = []
        do {
            if source.needsMicrophone {
                let recorder = try micFactory()
                recorder.levelHandler = { [weak self] level in
                    Task { @MainActor in self?.micLevel = level }
                }
                let url = directory.appendingPathComponent("\(base).caf")
                try recorder.start(to: url)
                trackURLs.append(url)
                started.append(recorder)
                micRecorder = recorder
            }
            if source.needsSystemAudio {
                let recorder = try systemFactory()
                recorder.levelHandler = { [weak self] level in
                    Task { @MainActor in self?.systemLevel = level }
                }
                // В режиме .both системная дорожка получает суффикс,
                // в режиме .system она единственная — имя без суффикса.
                let fileName = source == .both
                    ? "\(base)\(RecordingNamer.systemTrackSuffix).caf"
                    : "\(base).caf"
                let url = directory.appendingPathComponent(fileName)
                try recorder.start(to: url)
                trackURLs.append(url)
                started.append(recorder)
                systemRecorder = recorder
            }
        } catch {
            // Частично стартовавшие дорожки гасим, файлы-огрызки подчищаем:
            // сессия остаётся в idle, пользователь может поменять источник.
            for recorder in started { _ = try? recorder.stop() }
            for url in trackURLs { try? FileManager.default.removeItem(at: url) }
            micRecorder = nil
            systemRecorder = nil
            trackURLs = []
            currentBaseName = nil
            throw error
        }

        segmentStart = clock()
        state = .recording
        startTimer()
    }

    func pause() throws {
        guard state == .recording else {
            throw AudioRecordingError.invalidTransition(from: state, action: "pause")
        }
        micRecorder?.pause()
        systemRecorder?.pause()
        accumulated += clock() - (segmentStart ?? clock())
        segmentStart = nil
        state = .paused
    }

    func resume() throws {
        guard state == .paused else {
            throw AudioRecordingError.invalidTransition(from: state, action: "resume")
        }
        micRecorder?.resume()
        systemRecorder?.resume()
        segmentStart = clock()
        state = .recording
    }

    /// Останавливает запись, перепаковывает дорожки в .m4a и пишет sidecar.
    ///
    /// Устойчивость (фикс каскадного сбоя транскрипции):
    ///  - пустые дорожки (микрофон без разрешения/сигнала) отсеиваются — иначе
    ///    их remux падает и роняет весь stop(), теряя валидную вторую дорожку;
    ///  - если конвертация валидной дорожки всё же упала, она сохраняется как
    ///    .caf (звук не теряется: .caf читается плеером, recoverOrphans перепакует);
    ///  - source в метаданных отражает реально сохранённые дорожки;
    ///  - если не записалось НИЧЕГО — бросаем noAudioCaptured (понятно пользователю).
    func stop() async throws -> Result {
        guard state == .recording || state == .paused else {
            throw AudioRecordingError.invalidTransition(from: state, action: "stop")
        }
        if let segment = segmentStart {
            accumulated += clock() - segment
            segmentStart = nil
        }
        timer?.invalidate()
        timer = nil
        elapsed = accumulated

        // Останавливаем дорожки, помня их вид — source ниже пересчитывается по
        // тому, что реально уцелело.
        var rawTracks: [(url: URL, isSystem: Bool)] = []
        if let mic = micRecorder { rawTracks.append((try mic.stop(), false)) }
        if let system = systemRecorder { rawTracks.append((try system.stop(), true)) }
        micRecorder = nil
        systemRecorder = nil
        state = .stopped

        var finalFiles: [URL] = []
        var keptMic = false
        var keptSystem = false
        for track in rawTracks {
            // Пустая дорожка: не конвертируем (пустой CAF роняет remux) и не
            // включаем в запись — транскрибировать нечего, .caf убираем.
            if trackIsEmpty(track.url) {
                try? FileManager.default.removeItem(at: track.url)
                continue
            }
            do {
                finalFiles.append(try await convert(track.url))
            } catch {
                // Капризный контейнер: сохраняем дорожку как .caf, чтобы не
                // потерять звук. Запись НЕ теряется.
                finalFiles.append(track.url)
            }
            if track.isSystem { keptSystem = true } else { keptMic = true }
        }

        guard !finalFiles.isEmpty else {
            throw AudioRecordingError.noAudioCaptured
        }

        // Фактический источник: в режиме .both могла выпасть одна из дорожек.
        let effectiveSource: RecordingSource =
            (keptMic && keptSystem) ? .both : (keptSystem ? .system : .microphone)

        let metadata = RecordingMetadata(date: startedAt,
                                         duration: accumulated,
                                         source: effectiveSource,
                                         files: finalFiles.map { $0.lastPathComponent })
        let sidecarURL = RecordingMetadataStore.sidecarURL(base: currentBaseName ?? "",
                                                           in: directory)
        do {
            try RecordingMetadataStore.save(metadata, to: sidecarURL)
        } catch {
            throw AudioRecordingError.fileWriteFailed(error.localizedDescription)
        }
        return Result(audioFiles: finalFiles, sidecarURL: sidecarURL, metadata: metadata)
    }

    // MARK: - Внутренности

    /// Имя занято, если существует любой файл записи с этим базовым именем.
    private func uniqueBaseName(for date: Date) -> String {
        let fm = FileManager.default
        return RecordingNamer.uniqueBaseName(for: date) { candidate in
            let variants = [
                "\(candidate).m4a", "\(candidate).caf", "\(candidate).json",
                "\(candidate)\(RecordingNamer.systemTrackSuffix).m4a",
                "\(candidate)\(RecordingNamer.systemTrackSuffix).caf"
            ]
            return variants.contains { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
    }

    /// Таймер UI: раз в полсекунды публикует elapsed (сам счёт — в duration).
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = self.duration
            }
        }
    }
}
