// EscalationCoreTests.swift — чистое ядро каскадной эскалации (задача 91): таблица
// shouldEscalate по всем парам enabled×verdict, escalationPipelineConfig гасит только
// redundancy, composeMessage по всем ветками Attempt (nil/succeeded/failed/unavailable),
// снисходительные декодеры EscalationStatus/EscalationRecord («значение из будущего»,
// `{}` → дефолты), round-trip Codable.
// Задача 93: `EscalationTargetKind` — миграция файлов эпохи 91 (JSON без `kind`) на
// `.registry`, незнакомый `kind` «из будущего» → `.registry`, round-trip `.localTuned`.

import XCTest
@testable import SecondBrain

final class EscalationCoreTests: XCTestCase {

    // MARK: - shouldEscalate

    func testShouldEscalateTable() {
        let cases: [(enabled: Bool, verdict: ConfidenceVerdict, expected: Bool)] = [
            (false, .ok, false),
            (false, .unsure, false),
            (false, .fail, false),
            (true, .ok, false),
            (true, .unsure, true),
            (true, .fail, true),
        ]
        for c in cases {
            let name = "enabled=\(c.enabled) verdict=\(c.verdict)"
            XCTAssertEqual(EscalationCore.shouldEscalate(enabled: c.enabled, verdict: c.verdict), c.expected, name)
        }
    }

    // MARK: - escalationPipelineConfig

    func testEscalationPipelineConfigGatesOnlyRedundancyFromAllEnabled() {
        let result = EscalationCore.escalationPipelineConfig(from: .allEnabled)
        XCTAssertTrue(result.constraintEnabled)
        XCTAssertFalse(result.redundancyEnabled, "повторы на облаке дороги — принудительно OFF")
        XCTAssertTrue(result.scoringEnabled)
        XCTAssertTrue(result.selfCheckEnabled)
    }

    func testEscalationPipelineConfigPreservesPartiallyEnabledTogglesExceptRedundancy() {
        let partial = ConfidencePipelineConfig(constraintEnabled: false, redundancyEnabled: true,
                                                scoringEnabled: true, selfCheckEnabled: false)
        let result = EscalationCore.escalationPipelineConfig(from: partial)
        XCTAssertFalse(result.constraintEnabled, "constraint не тронут")
        XCTAssertFalse(result.redundancyEnabled, "redundancy гасится, даже если был включён")
        XCTAssertTrue(result.scoringEnabled, "scoring не тронут")
        XCTAssertFalse(result.selfCheckEnabled, "selfCheck не тронут")
    }

    func testEscalationPipelineConfigFromDefaultKeepsRedundancyOff() {
        let result = EscalationCore.escalationPipelineConfig(from: .default)
        XCTAssertEqual(result, .default, "дефолт уже без redundancy — функция его не меняет")
    }

    // MARK: - composeMessage

    private func makeReport(verdict: ConfidenceVerdict, promptTokens: Int = 1) -> ConfidenceReport {
        ConfidenceReport(verdict: verdict, reasons: ["причина"],
                          metrics: ConfidenceMetrics(totalCalls: 1, promptTokens: promptTokens), checks: [])
    }

    func testComposeMessageWithNilAttemptShowsCheapAnswerWithoutEscalationRecord() {
        let cheapReport = makeReport(verdict: .ok)
        let result = EscalationCore.composeMessage(primaryAnswer: "дешёвый ответ", primaryReport: cheapReport, attempt: nil)
        XCTAssertEqual(result.content, "дешёвый ответ")
        XCTAssertEqual(result.report, cheapReport)
        XCTAssertNil(result.escalation)
    }

    func testComposeMessageSucceededShowsStrongAnswerAndKeepsPrimaryReportInRecord() throws {
        let cheapReport = makeReport(verdict: .unsure)
        let strongReport = makeReport(verdict: .ok, promptTokens: 99)
        let attempt = EscalationCore.Attempt.succeeded(answer: "сильный ответ", report: strongReport,
                                                        providerID: "openai", model: "gpt-5")
        let result = EscalationCore.composeMessage(primaryAnswer: "дешёвый ответ", primaryReport: cheapReport, attempt: attempt)
        XCTAssertEqual(result.content, "сильный ответ")
        XCTAssertEqual(result.report, strongReport, "показанный report — сильной модели")
        let record = try XCTUnwrap(result.escalation)
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.trigger, .unsure, "trigger — вердикт дешёвой ступени")
        XCTAssertEqual(record.providerID, "openai")
        XCTAssertEqual(record.model, "gpt-5")
        XCTAssertEqual(record.primaryReport, cheapReport, "дешёвый отчёт уезжает в запись")
        XCTAssertNil(record.failureReason)
    }

    func testComposeMessageFailedKeepsCheapAnswerWithFailureReasonAndNoPrimaryReportDup() throws {
        let cheapReport = makeReport(verdict: .fail)
        let attempt = EscalationCore.Attempt.failed(reason: "сеть недоступна", providerID: "openai", model: "gpt-5")
        let result = EscalationCore.composeMessage(primaryAnswer: "дешёвый ответ", primaryReport: cheapReport, attempt: attempt)
        XCTAssertEqual(result.content, "дешёвый ответ")
        XCTAssertEqual(result.report, cheapReport)
        let record = try XCTUnwrap(result.escalation)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.trigger, .fail)
        XCTAssertEqual(record.failureReason, "сеть недоступна")
        XCTAssertNil(record.primaryReport, "primaryReport не дублируется при неуспехе")
    }

    func testComposeMessageUnavailableKeepsCheapAnswerWithReasonAndNoPrimaryReport() throws {
        let cheapReport = makeReport(verdict: .unsure)
        let attempt = EscalationCore.Attempt.unavailable(reason: "модель эскалации не выбрана")
        let result = EscalationCore.composeMessage(primaryAnswer: "дешёвый ответ", primaryReport: cheapReport, attempt: attempt)
        XCTAssertEqual(result.content, "дешёвый ответ")
        XCTAssertEqual(result.report, cheapReport)
        let record = try XCTUnwrap(result.escalation)
        XCTAssertEqual(record.status, .unavailable)
        XCTAssertEqual(record.trigger, .unsure)
        XCTAssertEqual(record.failureReason, "модель эскалации не выбрана")
        XCTAssertNil(record.providerID, "unavailable — до резолва провайдера, providerID/model нет")
        XCTAssertNil(record.primaryReport)
    }

    // MARK: - Снисходительные декодеры

    func testEscalationStatusUnknownRawValueDecodesToFailed() throws {
        let json = Data(#""будущий-статус""#.utf8)
        let decoded = try JSONDecoder().decode(EscalationStatus.self, from: json)
        XCTAssertEqual(decoded, .failed)
    }

    func testEscalationStatusKnownValuesRoundTrip() throws {
        for status: EscalationStatus in [.succeeded, .failed, .unavailable] {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(EscalationStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func testEscalationRecordFromEmptyObjectDecodesToDefaults() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(EscalationRecord.self, from: json)
        XCTAssertEqual(decoded.status, .failed)
        XCTAssertEqual(decoded.trigger, .unsure)
        XCTAssertNil(decoded.providerID)
        XCTAssertNil(decoded.model)
        XCTAssertNil(decoded.failureReason)
        XCTAssertNil(decoded.primaryReport)
    }

    func testEscalationRecordWithFutureStatusInJSONDecodesToFailed() throws {
        let json = Data(#"{"status":"из-будущего","trigger":"ok"}"#.utf8)
        let decoded = try JSONDecoder().decode(EscalationRecord.self, from: json)
        XCTAssertEqual(decoded.status, .failed)
        XCTAssertEqual(decoded.trigger, .ok)
    }

    func testEscalationRecordRoundTrip() throws {
        let report = makeReport(verdict: .unsure)
        let record = EscalationRecord(status: .succeeded, trigger: .fail, providerID: "openai",
                                       model: "gpt-5", failureReason: nil, primaryReport: report)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(EscalationRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func testEscalationTargetRoundTripWithEmptyModel() throws {
        let target = EscalationTarget(providerID: "openai", model: "")
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(EscalationTarget.self, from: data)
        XCTAssertEqual(decoded, target)
    }

    // MARK: - Задача 93: EscalationTargetKind

    /// Файл эпохи 91 — `kind` в JSON нет вовсе. `decodeIfPresent` обязан молча дать `.registry`.
    func testEscalationTargetFromEpoch91JSONWithoutKindMigratesToRegistry() throws {
        let json = Data(#"{"providerID":"openai","model":"gpt-5"}"#.utf8)
        let decoded = try JSONDecoder().decode(EscalationTarget.self, from: json)
        XCTAssertEqual(decoded.kind, .registry)
        XCTAssertEqual(decoded.providerID, "openai")
        XCTAssertEqual(decoded.model, "gpt-5")
    }

    /// Незнакомое значение `kind` «из будущего» — деградация в `.registry`, не краш
    /// декодера (симметрично `EscalationStatus`).
    func testEscalationTargetKindUnknownRawValueDecodesToRegistry() throws {
        let json = Data(#""будущий-kind""#.utf8)
        let decoded = try JSONDecoder().decode(EscalationTargetKind.self, from: json)
        XCTAssertEqual(decoded, .registry)
    }

    func testEscalationTargetWithFutureKindInJSONMigratesToRegistry() throws {
        let json = Data(#"{"providerID":"mlx-local","model":"Qwen2.5-7B-Instruct-4bit","kind":"из-будущего"}"#.utf8)
        let decoded = try JSONDecoder().decode(EscalationTarget.self, from: json)
        XCTAssertEqual(decoded.kind, .registry, "незнакомый kind → безопасная деградация в .registry")
    }

    func testEscalationTargetKindKnownValuesRoundTrip() throws {
        for kind: EscalationTargetKind in [.registry, .localTuned] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(EscalationTargetKind.self, from: data)
            XCTAssertEqual(decoded, kind, "kind=\(kind)")
        }
    }

    /// Цель `.localTuned` — providerID сентинел `localTunedProviderID`, `kind` сохраняется
    /// (не теряется/не мигрирует на `.registry` при явном значении).
    func testEscalationTargetLocalTunedRoundTripKeepsKindAndSentinelProviderID() throws {
        let target = EscalationTarget(providerID: .localTunedProviderID, model: "Qwen2.5-7B-Instruct-4bit", kind: .localTuned)
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(EscalationTarget.self, from: data)
        XCTAssertEqual(decoded, target)
        XCTAssertEqual(decoded.kind, .localTuned)
        XCTAssertEqual(decoded.providerID, ProviderID(rawValue: "mlx-local"))
    }

    func testLocalTunedProviderIDRawValue() {
        XCTAssertEqual(ProviderID.localTunedProviderID.rawValue, "mlx-local")
    }
}
