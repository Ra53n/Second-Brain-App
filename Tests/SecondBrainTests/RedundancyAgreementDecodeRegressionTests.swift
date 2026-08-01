// RedundancyAgreementDecodeRegressionTests.swift — регрессия задачи 85: незнакомый
// redundancy-raw в персистентном JSON ронял декод целиком.
//
// Тот же баг, что был у `ConfidenceVerdict` (см. `ConfidenceVerdictDecodeRegressionTests`):
// `RedundancyAgreement` — синтезированный `Codable` поверх `String` без своего
// `init(from:)`. `ConfidenceReport.redundancy`/`BatchRow.redundancy` читают его через
// `decodeIfPresent(...)`, но при наличии ключа с непонятной строкой (redundancy из более
// новой версии приложения) decodeIfPresent сам бросает DecodingError.dataCorrupted — это
// разваливает декод всего документа: `TuningChatPersistence.load` карантинит ВЕСЬ
// `finetune-chat.json` из-за одного сообщения с «сигналом из будущего». Починено:
// `RedundancyAgreement.init(from:)` — незнакомая строка → `.disagree` (неизвестный сигнал
// согласия не должен молча повышать уверенность).

import XCTest
@testable import SecondBrain

final class RedundancyAgreementDecodeRegressionTests: XCTestCase {

    func testUnknownRedundancyRawValueDecodesAsDisagreeNotThrow() throws {
        let json = #"{"verdict":"ok","reasons":[],"metrics":{},"checks":[],"redundancy":"mostly_agree"}"#
        let report = try JSONDecoder().decode(ConfidenceReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.redundancy, .disagree, "незнакомый сигнал согласия — безопасный дефолт, не крах")
    }

    func testUnknownRedundancyInBatchRowDecodesAsDisagree() throws {
        let json = #"{"index":1,"kind":"непустой","verdict":"ok","checksPassed":1,"checksTotal":1,"redundancy":"quorum"}"#
        let row = try JSONDecoder().decode(BatchRow.self, from: Data(json.utf8))
        XCTAssertEqual(row.redundancy, .disagree)
    }

    func testKnownRedundancyValuesStillRoundTrip() throws {
        for agreement in [RedundancyAgreement.agree, .partial, .disagree] {
            let data = try JSONEncoder().encode(agreement)
            let decoded = try JSONDecoder().decode(RedundancyAgreement.self, from: data)
            XCTAssertEqual(decoded, agreement, "\(agreement) обязан пережить round-trip")
        }
    }

    /// Полный документ `finetune-chat.json` с одним «нормальным» и одним «из будущего»
    /// сообщением — до фикса карантинил весь чат из-за одного redundancy.
    func testChatDocumentWithFutureRedundancyMessageStillLoadsWholeHistory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appendingPathComponent("finetune-chat.json")

        let json = """
        {"messages":[
          {"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"старое сообщение"},
          {"id":"22222222-2222-2222-2222-222222222222","role":"assistant","content":"{\\"action_items\\":[]}",
           "report":{"verdict":"ok","reasons":["r"],"metrics":{},"checks":[],"redundancy":"future_signal"},
           "modelVariant":"tuned"}
        ],"modelVariant":"baseline"}
        """
        try Data(json.utf8).write(to: url)

        let loaded = TuningChatPersistence.load(from: url)
        let baselineThread = try XCTUnwrap(loaded.threads[FineTuneModelVariant.baseline.rawValue])
        XCTAssertEqual(baselineThread.messages.count, 2, "оба сообщения читаются, не карантин целиком")
        XCTAssertEqual(baselineThread.messages[0].content, "старое сообщение")
        XCTAssertEqual(baselineThread.messages[1].report?.redundancy, .disagree)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.deletingPathExtension().appendingPathExtension("corrupt.json").path),
            "документ не карантинится из-за незнакомого redundancy одного сообщения")
    }
}
