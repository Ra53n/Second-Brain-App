// TuningChatStoreTests.swift — персистентность мини-чата тюнинга (задача 85, P2, задача
// 89 — раздельные треды по варианту): round-trip, карантин битого файла, миграция
// плоского старого документа в `threads`, незнакомый вариант в ключе не роняет декод.

import XCTest
@testable import SecondBrain

final class TuningChatStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRoundTrip() {
        let url = tempDir.appendingPathComponent("chat.json")
        let report = ConfidenceReport(
            verdict: .ok, reasons: ["ок"], metrics: ConfidenceMetrics(totalCalls: 1),
            checks: [ConfidenceCheckSummary(name: "валидный JSON", status: "pass", detail: nil)])
        let document = TuningChatDocument(
            threads: [
                "baseline": TuningChatThread(
                    messages: [
                        TuningChatMessage(role: "user", content: "Привет"),
                        TuningChatMessage(role: "assistant", content: "{\"action_items\":[]}",
                                          report: report, modelVariant: "baseline"),
                    ],
                    pipelineConfig: .default),
                "tuned": TuningChatThread(messages: [], pipelineConfig: .allEnabled),
            ],
            modelVariant: "tuned")
        TuningChatPersistence.save(document, to: url)
        XCTAssertEqual(TuningChatPersistence.load(from: url), document)
    }

    func testCorruptFileIsQuarantinedAndReturnsEmptyDocument() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        try Data("не json вовсе".utf8).write(to: url)
        XCTAssertEqual(TuningChatPersistence.load(from: url), TuningChatDocument())
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingFileReturnsEmptyDocument() {
        let url = tempDir.appendingPathComponent("missing.json")
        XCTAssertEqual(TuningChatPersistence.load(from: url), TuningChatDocument())
    }

    /// Задача 89: старый плоский документ (`messages`/`pipelineConfig` на верхнем уровне,
    /// без `threads`) — история целиком уезжает в тред активного `modelVariant`,
    /// конфиг копируется в оба треда, ничего не теряется.
    func testMigrationFromFlatDocumentMovesMessagesToActiveThreadAndConfigToBoth() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"messages":[{"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"Привет"}],
        "modelVariant":"tuned",
        "pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":true,"scoringEnabled":false,"selfCheckEnabled":true}}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)

        XCTAssertEqual(loaded.modelVariant, "tuned")
        let tunedThread = try XCTUnwrap(loaded.threads["tuned"])
        XCTAssertEqual(tunedThread.messages.count, 1)
        XCTAssertEqual(tunedThread.messages[0].content, "Привет")
        let expectedConfig = ConfidencePipelineConfig(constraintEnabled: true, redundancyEnabled: true,
                                                        scoringEnabled: false, selfCheckEnabled: true)
        XCTAssertEqual(tunedThread.pipelineConfig, expectedConfig)

        let baselineThread = try XCTUnwrap(loaded.threads["baseline"])
        XCTAssertTrue(baselineThread.messages.isEmpty, "история user-сообщений в baseline не расщепляется")
        XCTAssertEqual(baselineThread.pipelineConfig, expectedConfig, "конфиг копируется в оба треда")
    }

    /// Поля report/modelVariant/createdAt появились позже — старый JSON без них грузится с дефолтами.
    func testMigrationFromMinimalJSON() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"messages":[{"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"Привет"}],"modelVariant":"tuned"}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)
        let tunedThread = try XCTUnwrap(loaded.threads["tuned"])
        XCTAssertEqual(tunedThread.messages.count, 1)
        XCTAssertEqual(tunedThread.messages[0].content, "Привет")
        XCTAssertNil(tunedThread.messages[0].report)
        XCTAssertNil(tunedThread.messages[0].modelVariant)
        XCTAssertEqual(loaded.modelVariant, "tuned")
        XCTAssertEqual(tunedThread.pipelineConfig, .default, "поле появилось в задаче 86 — старый документ мигрирует на дефолт")
    }

    /// `pipelineConfig` появилось в задаче 86 — старый `finetune-chat.json` без него
    /// обязан грузиться с продовым дефолтом (только constraint), не падать.
    func testPipelineConfigMigratesToDefaultWhenAbsent() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = "{\"messages\":[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"role\":\"user\",\"content\":\"x\"}],\"modelVariant\":\"baseline\"}"
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)
        let baselineThread = try XCTUnwrap(loaded.threads["baseline"])
        XCTAssertEqual(baselineThread.pipelineConfig, ConfidencePipelineConfig(
            constraintEnabled: true, redundancyEnabled: false, scoringEnabled: false, selfCheckEnabled: false))
    }

    func testPipelineConfigRoundTripsWithAllFlagsSet() {
        let url = tempDir.appendingPathComponent("chat.json")
        let config = ConfidencePipelineConfig(constraintEnabled: true, redundancyEnabled: true,
                                               scoringEnabled: false, selfCheckEnabled: true)
        let document = TuningChatDocument(threads: ["baseline": TuningChatThread(pipelineConfig: config)])
        TuningChatPersistence.save(document, to: url)
        XCTAssertEqual(TuningChatPersistence.load(from: url).threads["baseline"]?.pipelineConfig, config)
    }

    func testEmptyJSONObjectMigratesToEmptyDocument() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(TuningChatPersistence.load(from: url), TuningChatDocument())
    }

    /// Новый формат: незнакомый вариант в ключе `threads` («значение из будущего») —
    /// декод не падает, известные треды целы.
    func testUnknownVariantKeyInThreadsDoesNotFailDecodeAndKeepsKnownThreads() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"threads":{"baseline":{"messages":[],"pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":false,"scoringEnabled":false,"selfCheckEnabled":false}},
        "future-variant":{"messages":[{"id":"22222222-2222-2222-2222-222222222222","role":"user","content":"из будущего"}],"pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":false,"scoringEnabled":false,"selfCheckEnabled":false}}},
        "modelVariant":"baseline"}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertEqual(loaded.modelVariant, "baseline")
        XCTAssertNotNil(loaded.threads["baseline"])
        XCTAssertNotNil(loaded.threads["future-variant"], "незнакомый тред сохраняется как есть, не выбрасывается")
    }
}
