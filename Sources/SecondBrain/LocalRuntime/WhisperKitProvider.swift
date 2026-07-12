// WhisperKitProvider.swift — локальная транскрипция как TranscriptionProvider
// (задача 10). WhisperKit (CoreML) работает in-process: модель грузится лениво
// при первой транскрипции, held в памяти между вызовами (загрузка large — до
// минуты) и ВЫГРУЖАЕТСЯ по idle (модель — гигабайты RAM; рядом ещё Ollama, см.
// IdleShutdownPolicy из задачи 09). Прогресс транскрипции публикуется наружу —
// длинная встреча обрабатывается минуты.
//
// Движок за протоколом WhisperEngine: реальная реализация — тонкий адаптер над
// WhisperKit (не тестируется), вся логика провайдера (ленивая загрузка,
// idle-выгрузка, выбор модели, маппинг) — на моках.

import Combine
import Foundation
import WhisperKit

/// Абстракция движка транскрипции (реальная — WhisperKitEngine).
protocol WhisperEngine: AnyObject {
    /// onProgress: доля 0…1 или nil (неизвестно); вызывается с фонового потока.
    func transcribe(audioURL: URL,
                    language: String?,
                    onProgress: @escaping @Sendable (Double?) -> Void) async throws -> WhisperEngineOutput
}

/// Тонкий адаптер над WhisperKit.
final class WhisperKitEngine: WhisperEngine {
    private let pipe: WhisperKit

    /// Инициализация грузит (и при необходимости скачивает) модель.
    init(variant: String, downloadBase: URL) async throws {
        let config = WhisperKitConfig(model: variant, downloadBase: downloadBase)
        pipe = try await WhisperKit(config)
    }

    func transcribe(audioURL: URL,
                    language: String?,
                    onProgress: @escaping @Sendable (Double?) -> Void) async throws -> WhisperEngineOutput {
        var options = DecodingOptions()
        options.language = language
        options.task = .transcribe
        // Прогресс: WhisperKit не отдаёт долю напрямую — оцениваем по номеру
        // 30-секундного окна против длительности файла.
        let duration = AudioFileConverter.audioDuration(of: audioURL)
        let results = try await pipe.transcribe(audioPath: audioURL.path,
                                                decodeOptions: options) { progress in
            if duration > 0 {
                onProgress(min(1, Double(progress.windowId + 1) * 30.0 / duration))
            } else {
                onProgress(nil)
            }
            return nil // продолжать
        }
        let segments = results.flatMap(\.segments).map {
            WhisperSegmentData(text: $0.text, start: Double($0.start), end: Double($0.end))
        }
        return WhisperEngineOutput(segments: segments, language: results.first?.language)
    }
}

/// Провайдер локальной транскрипции.
@MainActor
final class WhisperKitProvider: ObservableObject, TranscriptionProvider {
    static let id: ProviderID = "whisperkit"

    enum EngineState: Equatable {
        case unloaded
        case loading        // скачивание/загрузка модели в память
        case ready(String)  // загружен вариант
        case transcribing(String)
    }

    @Published private(set) var engineState: EngineState = .unloaded
    /// Доля готовности текущей транскрипции (nil — не идёт/неизвестно).
    @Published private(set) var transcriptionProgress: Double?

    /// Выбранный вариант модели; персистентно в UserDefaults.
    @Published var selectedVariant: String {
        didSet { defaults.set(selectedVariant, forKey: Self.variantKey) }
    }

    static let variantKey = "whisperkit.selectedVariant"

    private let downloadBase: URL
    private let defaults: UserDefaults
    private let engineFactory: (String, URL) async throws -> WhisperEngine
    private let idlePolicy: IdleShutdownPolicy
    private var engine: WhisperEngine?
    private var loadedVariant: String?
    private var idleTimer: Timer?

    init(downloadBase: URL = WhisperModelStorage.defaultDownloadBase,
         defaults: UserDefaults = .standard,
         idlePolicy: IdleShutdownPolicy = IdleShutdownPolicy(),
         engineFactory: @escaping (String, URL) async throws -> WhisperEngine = { variant, base in
             try await WhisperKitEngine(variant: variant, downloadBase: base)
         }) {
        self.downloadBase = downloadBase
        self.defaults = defaults
        self.idlePolicy = idlePolicy
        self.engineFactory = engineFactory
        self.selectedVariant = defaults.string(forKey: Self.variantKey)
            ?? WhisperVariant.recommendedName
        startIdleTimer()
    }

    /// Есть ли хоть одна установленная модель (isAvailable в реестре: без неё
    /// роутер не должен выбирать Whisper — иначе внезапная закачка гигабайтов).
    nonisolated func hasInstalledModel(base: URL) -> Bool {
        !WhisperModelStorage.installedVariants(base: base).isEmpty
    }

    // MARK: - TranscriptionProvider

    func transcribe(audioURL: URL, language: String?, hints: String?) async throws -> Transcript {
        idlePolicy.markUsed()
        let variant = selectedVariant
        let activeEngine: WhisperEngine
        if let engine, loadedVariant == variant {
            activeEngine = engine // повторная транскрипция не перегружает модель
        } else {
            engine = nil // смена варианта — старую модель освобождаем сразу
            engineState = .loading
            do {
                activeEngine = try await engineFactory(variant, downloadBase)
            } catch {
                engineState = .unloaded
                throw error
            }
            engine = activeEngine
            loadedVariant = variant
        }
        engineState = .transcribing(variant)
        transcriptionProgress = 0
        defer {
            engineState = .ready(variant)
            transcriptionProgress = nil
            idlePolicy.markUsed()
        }
        let output = try await activeEngine.transcribe(
            audioURL: audioURL,
            language: language
        ) { [weak self] fraction in
            Task { @MainActor in self?.transcriptionProgress = fraction }
        }
        return WhisperMapping.transcript(from: output)
    }

    // MARK: - Память

    /// Выгрузка простаивающей модели (гигабайты RAM). Зовётся таймером и тестами.
    func unloadIfIdle() {
        guard engine != nil, idlePolicy.shouldShutdown else { return }
        unloadNow()
    }

    func unloadNow() {
        // Во время транскрипции не выгружаем (движок держит текущий вызов).
        if case .transcribing = engineState { return }
        engine = nil
        loadedVariant = nil
        engineState = .unloaded
    }

    var isEngineLoaded: Bool { engine != nil }

    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.unloadIfIdle() }
        }
    }
}
