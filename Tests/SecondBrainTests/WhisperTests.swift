// WhisperTests.swift — задача 10: маппинг результата WhisperKit → Transcript
// (по фикстуре), логика выбора/хранения моделей (скан temp-директорий),
// ленивая загрузка/idle-выгрузка движка на моках с инжектированными часами.

import XCTest
@testable import SecondBrain

// MARK: - Маппинг

final class WhisperMappingTests: XCTestCase {

    private func fixtureOutput() throws -> WhisperEngineOutput {
        let url = Bundle.module.url(forResource: "whisper_segments",
                                    withExtension: "json", subdirectory: "Fixtures")!
        let segments = try JSONDecoder().decode([WhisperSegmentData].self,
                                                from: Data(contentsOf: url))
        return WhisperEngineOutput(segments: segments, language: "ru")
    }

    func testMappingFromFixture() throws {
        let transcript = WhisperMapping.transcript(from: try fixtureOutput())
        XCTAssertEqual(transcript.language, "ru")
        XCTAssertEqual(transcript.segments.count, 3, "пустой сегмент выброшен")
        XCTAssertEqual(transcript.segments[0].text, "Всем привет, начинаем встречу.")
        XCTAssertEqual(transcript.segments[0].start, 0.0)
        XCTAssertEqual(transcript.segments[0].end, 3.2)
        XCTAssertEqual(transcript.fullText,
                       "Всем привет, начинаем встречу. Сегодня обсуждаем релиз. Вопросы есть?")
    }

    func testMappingTrimsWhitespaceAndDropsEmpty() {
        let output = WhisperEngineOutput(segments: [
            WhisperSegmentData(text: "  привет \n", start: 0, end: 1),
            WhisperSegmentData(text: "   ", start: 1, end: 2),
        ], language: nil)
        let transcript = WhisperMapping.transcript(from: output)
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.fullText, "привет")
        XCTAssertNil(transcript.language)
    }

    func testMappingInvalidEndBecomesNil() {
        // Битый end (< start) не попадает в Transcript как заведомая ложь.
        let output = WhisperEngineOutput(segments: [
            WhisperSegmentData(text: "т", start: 5, end: 2)
        ], language: nil)
        XCTAssertNil(WhisperMapping.transcript(from: output).segments[0].end)
        XCTAssertEqual(WhisperMapping.transcript(from: output).segments[0].start, 5)
    }
}

// MARK: - Хранение моделей

final class WhisperModelStorageTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeVariantFolder(_ folder: String, withFile: Bool = true) throws {
        let dir = WhisperModelStorage.modelsRoot(base: base).appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withFile {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("model.mlmodelc").path,
                                           contents: Data(repeating: 0, count: 128))
        }
    }

    func testInstalledVariantsScan() throws {
        try makeVariantFolder("openai_whisper-large-v3_turbo")
        try makeVariantFolder("openai_whisper-tiny")
        XCTAssertEqual(WhisperModelStorage.installedVariants(base: base),
                       ["large-v3_turbo", "tiny"])
        XCTAssertTrue(WhisperModelStorage.isInstalled("tiny", base: base))
        XCTAssertFalse(WhisperModelStorage.isInstalled("medium", base: base))
    }

    func testInstalledVariantsEmptyWhenNothingDownloaded() {
        XCTAssertEqual(WhisperModelStorage.installedVariants(base: base), [])
    }

    func testDeleteRemovesVariantFolder() throws {
        try makeVariantFolder("openai_whisper-tiny")
        try WhisperModelStorage.delete("tiny", base: base)
        XCTAssertFalse(WhisperModelStorage.isInstalled("tiny", base: base))
    }

    func testSizeOnDisk() throws {
        try makeVariantFolder("openai_whisper-tiny")
        XCTAssertEqual(WhisperModelStorage.sizeOnDisk("tiny", base: base), 128)
        XCTAssertEqual(WhisperModelStorage.sizeOnDisk("нет", base: base), 0)
    }

    func testVariantNameParsing() {
        XCTAssertEqual(WhisperModelStorage.variantName(fromFolder: "openai_whisper-large-v3_turbo"),
                       "large-v3_turbo")
        XCTAssertEqual(WhisperModelStorage.variantName(fromFolder: "чужая-папка"), "чужая-папка")
    }
}

// MARK: - Провайдер: ленивая загрузка и idle-выгрузка

/// Мок движка: отдаёт заготовленный результат, считает вызовы.
private final class MockWhisperEngine: WhisperEngine {
    private(set) var transcribeCount = 0
    var output = WhisperEngineOutput(
        segments: [WhisperSegmentData(text: "тестовый текст", start: 0, end: 2)],
        language: "ru")

    func transcribe(audioURL: URL,
                    language: String?,
                    onProgress: @escaping @Sendable (Double?) -> Void) async throws -> WhisperEngineOutput {
        transcribeCount += 1
        onProgress(0.5)
        return output
    }
}

@MainActor
final class WhisperKitProviderTests: XCTestCase {
    private var engine: MockWhisperEngine!
    private var factoryCalls: [(String, URL)] = []
    private var now: TimeInterval = 0
    private var defaults: UserDefaults!
    private let suiteName = "WhisperKitProviderTests-\(UUID().uuidString)"

    override func setUpWithError() throws {
        engine = MockWhisperEngine()
        factoryCalls = []
        now = 0
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeProvider(idleTimeout: TimeInterval = 300) -> WhisperKitProvider {
        WhisperKitProvider(
            downloadBase: FileManager.default.temporaryDirectory,
            defaults: defaults,
            idlePolicy: IdleShutdownPolicy(timeout: idleTimeout, clock: { self.now }),
            engineFactory: { variant, base in
                self.factoryCalls.append((variant, base))
                return self.engine
            })
    }

    func testLazyLoadAndReuseAcrossTranscriptions() async throws {
        let provider = makeProvider()
        XCTAssertFalse(provider.isEngineLoaded, "до первой транскрипции модель не грузится")

        let transcript = try await provider.transcribe(
            audioURL: URL(fileURLWithPath: "/fake.m4a"), language: "ru", hints: nil)
        XCTAssertEqual(transcript.fullText, "тестовый текст")
        XCTAssertEqual(transcript.segments.first?.start, 0)
        XCTAssertEqual(factoryCalls.count, 1)
        XCTAssertTrue(provider.isEngineLoaded)

        // Повторная транскрипция НЕ пересоздаёт движок (и не перекачивает модель).
        _ = try await provider.transcribe(
            audioURL: URL(fileURLWithPath: "/fake2.m4a"), language: "ru", hints: nil)
        XCTAssertEqual(factoryCalls.count, 1, "движок переиспользован")
        XCTAssertEqual(engine.transcribeCount, 2)
    }

    func testIdleUnloadFreesEngine() async throws {
        let provider = makeProvider(idleTimeout: 300)
        _ = try await provider.transcribe(
            audioURL: URL(fileURLWithPath: "/fake.m4a"), language: nil, hints: nil)
        XCTAssertTrue(provider.isEngineLoaded)

        now = 100
        provider.unloadIfIdle()
        XCTAssertTrue(provider.isEngineLoaded, "окно простоя не истекло — модель в памяти")

        now = 400 // 300 c от последнего использования
        provider.unloadIfIdle()
        XCTAssertFalse(provider.isEngineLoaded, "простаивающая модель выгружена")
        XCTAssertEqual(provider.engineState, .unloaded)

        // Следующая транскрипция лениво грузит заново.
        _ = try await provider.transcribe(
            audioURL: URL(fileURLWithPath: "/fake.m4a"), language: nil, hints: nil)
        XCTAssertEqual(factoryCalls.count, 2)
    }

    func testVariantChangeReloadsEngine() async throws {
        let provider = makeProvider()
        _ = try await provider.transcribe(
            audioURL: URL(fileURLWithPath: "/fake.m4a"), language: nil, hints: nil)
        XCTAssertEqual(factoryCalls.last?.0, WhisperVariant.recommendedName)

        provider.selectedVariant = "tiny"
        _ = try await provider.transcribe(
            audioURL: URL(fileURLWithPath: "/fake.m4a"), language: nil, hints: nil)
        XCTAssertEqual(factoryCalls.count, 2, "смена модели пересоздаёт движок")
        XCTAssertEqual(factoryCalls.last?.0, "tiny")
    }

    func testSelectedVariantPersistsInDefaults() {
        let provider = makeProvider()
        provider.selectedVariant = "medium"
        // Новый провайдер с теми же defaults видит выбор.
        let second = makeProvider()
        XCTAssertEqual(second.selectedVariant, "medium")
    }

    func testFactoryFailureResetsState() async {
        let provider = WhisperKitProvider(
            downloadBase: FileManager.default.temporaryDirectory,
            defaults: defaults,
            idlePolicy: IdleShutdownPolicy(timeout: 300, clock: { self.now }),
            engineFactory: { _, _ in throw OllamaError.badURL }) // любая ошибка
        do {
            _ = try await provider.transcribe(
                audioURL: URL(fileURLWithPath: "/fake.m4a"), language: nil, hints: nil)
            XCTFail("ожидалась ошибка фабрики")
        } catch {
            XCTAssertEqual(provider.engineState, .unloaded)
            XCTAssertFalse(provider.isEngineLoaded)
        }
    }
}
