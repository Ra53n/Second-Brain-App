// ConfidenceVerdictDecodeRegressionTests.swift — регрессия задачи 85: незнакомый
// verdict-raw в персистентном JSON ронял декод целиком.
//
// Симптом: `ConfidenceVerdict` — синтезированный `Codable` поверх `String` без своего
// `init(from:)`. `ConfidenceReport.init(from:)`/`BatchRow.init(from:)` читают его через
// `decodeIfPresent(...) ?? .unsure`, но `decodeIfPresent` возвращает дефолт только когда
// ключ отсутствует или `null` — при наличии ключа с непонятной строкой (вердикт из более
// новой версии приложения) decodeIfPresent сам бросает DecodingError.dataCorrupted, и это
// разваливает декод всего документа: `TuningChatPersistence.load` карантинит ВЕСЬ
// `finetune-chat.json` из-за одного сообщения с «вердиктом из будущего», хотя остальные
// сообщения истории читаемы. Починено: `ConfidenceVerdict.init(from:)` — незнакомая строка
// → `.unsure` (тот же безопасный дефолт, что у отсутствующего поля), текст причин в
// `reasons` не теряется, поле `checks`/`metrics` тоже остаются на месте.
//
// Тот же паттерн (`RawRepresentable` без снисходительного декодера) есть у
// `RedundancyAgreement` (ConfidenceReport.redundancy / BatchRow.redundancy) — за рамками
// этой правки, см. отчёт тестов задачи 85.

import XCTest
@testable import SecondBrain

final class ConfidenceVerdictDecodeRegressionTests: XCTestCase {

    func testUnknownVerdictRawValueDecodesAsUnsureNotThrow() throws {
        let json = #"{"verdict":"partially_ok","reasons":["из будущей версии"],"metrics":{},"checks":[]}"#
        let report = try JSONDecoder().decode(ConfidenceReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.verdict, .unsure, "незнакомый вердикт — безопасный дефолт, не крах")
        XCTAssertEqual(report.reasons, ["из будущей версии"], "причины не теряются при фоллбэке вердикта")
    }

    func testUnknownVerdictInBatchRowDecodesAsUnsure() throws {
        let json = #"{"index":1,"kind":"непустой","verdict":"maybe","checksPassed":0,"checksTotal":0}"#
        let row = try JSONDecoder().decode(BatchRow.self, from: Data(json.utf8))
        XCTAssertEqual(row.verdict, .unsure)
    }

    func testKnownVerdictsStillRoundTrip() throws {
        for verdict in [ConfidenceVerdict.ok, .unsure, .fail] {
            let data = try JSONEncoder().encode(verdict)
            let decoded = try JSONDecoder().decode(ConfidenceVerdict.self, from: data)
            XCTAssertEqual(decoded, verdict, "\(verdict) обязан пережить round-trip")
        }
    }

    /// Полный документ `finetune-chat.json` с одним «нормальным» и одним «из будущего»
    /// сообщением — до фикса карантинил весь чат из-за одного вердикта.
    func testChatDocumentWithFutureVerdictMessageStillLoadsWholeHistory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appendingPathComponent("finetune-chat.json")

        let json = """
        {"messages":[
          {"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"старое сообщение"},
          {"id":"22222222-2222-2222-2222-222222222222","role":"assistant","content":"{\\"action_items\\":[]}",
           "report":{"verdict":"speculative","reasons":["r"],"metrics":{},"checks":[]},"modelVariant":"tuned"}
        ],"modelVariant":"baseline"}
        """
        try Data(json.utf8).write(to: url)

        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertEqual(loaded.messages.count, 2, "оба сообщения читаются, не карантин целиком")
        XCTAssertEqual(loaded.messages[0].content, "старое сообщение")
        XCTAssertEqual(loaded.messages[1].report?.verdict, .unsure)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.deletingPathExtension().appendingPathExtension("corrupt.json").path),
            "документ не карантинится из-за незнакомого вердикта одного сообщения")
    }
}
