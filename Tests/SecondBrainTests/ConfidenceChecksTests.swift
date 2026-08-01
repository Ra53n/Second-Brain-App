// ConfidenceChecksTests.swift — задача 85: constraint-проверки, обе формы. Reference-based
// случаи сверены с `finetune/actionitem_checks.run_checks()` (см. отчёт задачи).

import XCTest
@testable import SecondBrain

final class ConfidenceChecksTests: XCTestCase {

    private func outcome(_ checks: [ConfidenceCheck], _ name: String) -> CheckOutcome? {
        checks.first { $0.name == name }?.outcome
    }

    // MARK: - referenceFree

    /// Порядок как в python run_checks(): «валидный JSON» перед «без прозы» — отчёты
    /// чата и батча должны показывать проверки в одном порядке.
    func testReferenceFreeCheckOrderMatchesReferenceBased() {
        let raw = #"{"action_items": []}"#
        let checks = ConfidenceChecks.referenceFree(raw: raw, transcript: "текст")
        XCTAssertEqual(checks[0].name, "валидный JSON")
        XCTAssertEqual(checks[1].name, "без прозы")
    }

    func testReferenceFreeValidAnswerAllPass() {
        let raw = #"{"action_items": [{"assignee": "Аня", "task": "сделать отчёт", "due": "в пятницу"}]}"#
        let transcript = "Аня, пожалуйста, сделай отчёт в пятницу."
        let checks = ConfidenceChecks.referenceFree(raw: raw, transcript: transcript)
        for check in checks {
            XCTAssertEqual(check.outcome, .pass, check.name)
        }
    }

    func testReferenceFreeInventedDueFails() {
        let raw = #"{"action_items": [{"assignee": "Аня", "task": "сделать отчёт", "due": "вторник"}]}"#
        let transcript = "Аня сделает отчёт, сроков не называли."
        let checks = ConfidenceChecks.referenceFree(raw: raw, transcript: transcript)
        guard case .fail = outcome(checks, "срок из транскрипта") else {
            return XCTFail("выдуманный срок обязан провалить проверку")
        }
    }

    func testReferenceFreeAssigneeNotInTranscriptFails() {
        let raw = #"{"action_items": [{"assignee": "Петя", "task": "сделать отчёт", "due": null}]}"#
        let transcript = "Аня сделает отчёт."
        let checks = ConfidenceChecks.referenceFree(raw: raw, transcript: transcript)
        guard case .fail = outcome(checks, "ответственный из транскрипта") else {
            return XCTFail("ответственный не из транскрипта обязан провалить проверку")
        }
    }

    func testReferenceFreeInvalidJSONFailsAndRestNotApplicable() {
        let checks = ConfidenceChecks.referenceFree(raw: "мусор", transcript: "любой транскрипт")
        guard case .fail = outcome(checks, "валидный JSON") else { return XCTFail() }
        guard case .notApplicable = outcome(checks, "срок из транскрипта") else { return XCTFail() }
        guard case .notApplicable = outcome(checks, "ответственный из транскрипта") else { return XCTFail() }
    }

    func testReferenceFreeEmptyItemsNotApplicableForPerItemChecks() {
        let checks = ConfidenceChecks.referenceFree(raw: #"{"action_items": []}"#, transcript: "текст")
        XCTAssertEqual(outcome(checks, "валидный JSON"), .pass)
        guard case .notApplicable = outcome(checks, "срок из транскрипта") else { return XCTFail() }
    }

    // MARK: - referenceBased — таблица от run_checks (валидность JSON/прозы, схема)

    func testReferenceBasedInvalidJSONMakesRestNotApplicable() {
        let ref = #"{"action_items": []}"#
        let checks = ConfidenceChecks.referenceBased(raw: "мусор", reference: ref, transcript: "")
        guard case .fail = outcome(checks, "валидный JSON") else { return XCTFail() }
        for name in ["схема элементов", "число поручений", "ничего не выдумано", "ничего не упущено",
                     "ответственные совпадают", "срок не выдуман", "формулировка задачи"] {
            guard case .notApplicable = outcome(checks, name) else { return XCTFail(name) }
        }
    }

    func testReferenceBasedMissingItemKeyFailsSchemaOnly() {
        // Сверено с python: отсутствие ключа due — тоже нарушение схемы (не только лишний ключ).
        let raw = #"{"action_items": [{"assignee": "Аня", "task": "сделать"}]}"#
        let ref = #"{"action_items": [{"assignee": "Аня", "task": "сделать", "due": null}]}"#
        let checks = ConfidenceChecks.referenceBased(raw: raw, reference: ref, transcript: "")
        XCTAssertEqual(outcome(checks, "валидный JSON"), .pass)
        guard case .fail(let detail) = outcome(checks, "схема элементов") else { return XCTFail() }
        XCTAssertEqual(detail, "элементов с нарушенной схемой: 1")
        XCTAssertEqual(outcome(checks, "число поручений"), .pass)
        guard case .notApplicable = outcome(checks, "ответственные совпадают") else { return XCTFail() }
    }

    func testReferenceBasedPerfectMatchAllPass() {
        let ref = #"{"action_items": [{"assignee": "Аня", "task": "подготовить отчёт", "due": "пятница"}]}"#
        let raw = #"{"action_items": [{"assignee": "аня", "task": "подготовить отчет", "due": "пятница"}]}"#
        let checks = ConfidenceChecks.referenceBased(raw: raw, reference: ref, transcript: "")
        for check in checks where check.name != "ничего не выдумано" {
            XCTAssertEqual(check.outcome, .pass, check.name)
        }
        guard case .notApplicable = outcome(checks, "ничего не выдумано") else { return XCTFail() }
    }

    func testReferenceBasedInventedDueFails() {
        let raw = #"{"action_items": [{"assignee": "Аня", "task": "подготовить отчёт", "due": "пятница"}]}"#
        let ref = #"{"action_items": [{"assignee": "Аня", "task": "подготовить отчёт", "due": null}]}"#
        let checks = ConfidenceChecks.referenceBased(raw: raw, reference: ref, transcript: "")
        guard case .fail(let detail) = outcome(checks, "срок не выдуман") else { return XCTFail() }
        XCTAssertEqual(detail, "сроков больше эталона на 1")
    }

    func testReferenceBasedTaskSimilarityBelowThresholdFails() {
        let raw = #"{"action_items": [{"assignee": "Аня", "task": "купить кофе", "due": null}]}"#
        let ref = #"{"action_items": [{"assignee": "Аня", "task": "подготовить квартальный отчёт по продажам", "due": null}]}"#
        let checks = ConfidenceChecks.referenceBased(raw: raw, reference: ref, transcript: "")
        guard case .fail = outcome(checks, "формулировка задачи") else { return XCTFail() }
    }

    func testReferenceBasedEmptyReferenceExpectsEmptyModel() {
        let ref = #"{"action_items": []}"#
        let rawEmpty = #"{"action_items": []}"#
        let checksEmpty = ConfidenceChecks.referenceBased(raw: rawEmpty, reference: ref, transcript: "")
        XCTAssertEqual(outcome(checksEmpty, "ничего не выдумано"), .pass)
        guard case .notApplicable = outcome(checksEmpty, "ничего не упущено") else { return XCTFail() }
        guard case .notApplicable = outcome(checksEmpty, "ответственные совпадают") else { return XCTFail() }

        let rawInvented = #"{"action_items": [{"assignee": "Аня", "task": "сделать", "due": null}]}"#
        let checksInvented = ConfidenceChecks.referenceBased(raw: rawInvented, reference: ref, transcript: "")
        guard case .fail(let detail) = outcome(checksInvented, "ничего не выдумано") else { return XCTFail() }
        XCTAssertEqual(detail, "выдумано поручений: 1")
    }

    func testReferenceBasedNonEmptyReferenceButModelEmptyFailsMissedCheck() {
        let ref = #"{"action_items": [{"assignee": "Аня", "task": "сделать", "due": null}]}"#
        let raw = #"{"action_items": []}"#
        let checks = ConfidenceChecks.referenceBased(raw: raw, reference: ref, transcript: "")
        guard case .notApplicable = outcome(checks, "ничего не выдумано") else { return XCTFail() }
        guard case .fail = outcome(checks, "ничего не упущено") else { return XCTFail() }
    }
}
