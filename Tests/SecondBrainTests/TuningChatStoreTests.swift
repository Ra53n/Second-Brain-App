// TuningChatStoreTests.swift — персистентность мини-чата тюнинга (задача 85, P2):
// round-trip, карантин битого файла, миграция старого JSON без report/modelVariant/createdAt.

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
            messages: [
                TuningChatMessage(role: "user", content: "Привет"),
                TuningChatMessage(role: "assistant", content: "{\"action_items\":[]}",
                                  report: report, modelVariant: "baseline"),
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

    /// Поля report/modelVariant/createdAt появились позже — старый JSON без них грузится с дефолтами.
    func testMigrationFromMinimalJSON() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"messages":[{"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"Привет"}],"modelVariant":"tuned"}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertEqual(loaded.messages.count, 1)
        XCTAssertEqual(loaded.messages[0].content, "Привет")
        XCTAssertNil(loaded.messages[0].report)
        XCTAssertNil(loaded.messages[0].modelVariant)
        XCTAssertEqual(loaded.modelVariant, "tuned")
    }

    func testEmptyJSONObjectMigratesToEmptyDocument() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(TuningChatPersistence.load(from: url), TuningChatDocument())
    }
}
