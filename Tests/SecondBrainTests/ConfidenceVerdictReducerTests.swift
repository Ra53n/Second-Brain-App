// ConfidenceVerdictReducerTests.swift — задача 85: редьюсер сигналов в вердикт.
// Таблица случаев: каждый сигнал по отдельности + комбинации + все недоступны.

import XCTest
@testable import SecondBrain

final class ConfidenceVerdictReducerTests: XCTestCase {
    private let passChecks = [ConfidenceCheck(name: "валидный JSON", outcome: .pass, severity: .hard),
                               ConfidenceCheck(name: "без прозы", outcome: .pass, severity: .hard)]

    private func signals(constraintChecks: [ConfidenceCheck]? = nil, redundancy: RedundancyAgreement? = nil,
                          scoring: ScoringSignal? = nil, selfCheck: SelfCheckSignal? = nil) -> ConfidenceSignals {
        ConfidenceSignals(constraintChecks: constraintChecks ?? passChecks, redundancy: redundancy,
                          scoring: scoring, selfCheck: selfCheck)
    }

    // MARK: - hard constraint fail

    func testHardConstraintFailIsFailImmediately() {
        let checks = [ConfidenceCheck(name: "валидный JSON", outcome: .fail("не JSON"), severity: .hard)]
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals(constraintChecks: checks,
                                                                   redundancy: .agree,
                                                                   scoring: ScoringSignal(status: "OK", confidence: 90),
                                                                   selfCheck: SelfCheckSignal(supported: [true], reasons: [""], missed: false)))
        XCTAssertEqual(verdict, .fail)
        XCTAssertTrue(reasons.contains { $0.contains("валидный JSON") })
    }

    // MARK: - each signal alone

    func testAllSignalsAvailableAndGoodIsOK() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(
            redundancy: .agree,
            scoring: ScoringSignal(status: "OK", confidence: 90),
            selfCheck: SelfCheckSignal(supported: [true, true], reasons: ["", ""], missed: false)))
        XCTAssertEqual(verdict, .ok)
    }

    func testRedundancyDisagreeIsFail() {
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals(redundancy: .disagree))
        XCTAssertEqual(verdict, .fail)
        XCTAssertTrue(reasons.contains { $0.contains("не сошлись") })
    }

    func testRedundancyPartialIsUnsure() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(redundancy: .partial))
        XCTAssertEqual(verdict, .unsure)
    }

    func testRedundancyAgreeAloneIsOK() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(redundancy: .agree))
        XCTAssertEqual(verdict, .ok)
    }

    func testSelfCheckMajorityUnsupportedIsFail() {
        let selfCheck = SelfCheckSignal(supported: [false, false, true], reasons: ["", "", ""], missed: false)
        let (verdict, _) = ConfidenceVerdict.reduce(signals(selfCheck: selfCheck))
        XCTAssertEqual(verdict, .fail)
    }

    func testSelfCheckOneUnsupportedIsUnsure() {
        let selfCheck = SelfCheckSignal(supported: [false, true, true], reasons: ["", "", ""], missed: false)
        let (verdict, _) = ConfidenceVerdict.reduce(signals(selfCheck: selfCheck))
        XCTAssertEqual(verdict, .unsure)
    }

    func testSelfCheckAllSupportedIsOK() {
        let selfCheck = SelfCheckSignal(supported: [true, true], reasons: ["", ""], missed: false)
        let (verdict, _) = ConfidenceVerdict.reduce(signals(selfCheck: selfCheck))
        XCTAssertEqual(verdict, .ok)
    }

    func testSelfCheckMissedIsUnsure() {
        let selfCheck = SelfCheckSignal(supported: [true], reasons: [""], missed: true)
        let (verdict, _) = ConfidenceVerdict.reduce(signals(selfCheck: selfCheck))
        XCTAssertEqual(verdict, .unsure)
    }

    func testScoringConfidenceBelow40IsFail() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(scoring: ScoringSignal(status: nil, confidence: 20)))
        XCTAssertEqual(verdict, .fail)
    }

    func testScoringConfidenceMidRangeIsUnsure() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(scoring: ScoringSignal(status: nil, confidence: 55)))
        XCTAssertEqual(verdict, .unsure)
    }

    func testScoringConfidenceHighIsOK() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(scoring: ScoringSignal(status: nil, confidence: 95)))
        XCTAssertEqual(verdict, .ok)
    }

    func testScoringStatusFailOverridesHighConfidence() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(scoring: ScoringSignal(status: "FAIL", confidence: 95)))
        XCTAssertEqual(verdict, .fail)
    }

    func testScoringStatusUnsureWithoutConfidence() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(scoring: ScoringSignal(status: "UNSURE", confidence: nil)))
        XCTAssertEqual(verdict, .unsure)
    }

    func testConstraintWarningAloneIsUnsure() {
        let checks = passChecks + [ConfidenceCheck(name: "срок из транскрипта",
                                                     outcome: .fail("срок не из транскрипта"), severity: .warning)]
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals(constraintChecks: checks))
        XCTAssertEqual(verdict, .unsure)
        XCTAssertTrue(reasons.contains { $0.contains("срок из транскрипта") })
    }

    // MARK: - combinations

    func testWorstSignalWins() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(
            redundancy: .agree,
            scoring: ScoringSignal(status: "OK", confidence: 95),
            selfCheck: SelfCheckSignal(supported: [false, false], reasons: ["", ""], missed: false)))
        XCTAssertEqual(verdict, .fail)
    }

    func testUnsureAndOkCombinedIsUnsure() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(
            redundancy: .partial,
            scoring: ScoringSignal(status: "OK", confidence: 95)))
        XCTAssertEqual(verdict, .unsure)
    }

    // MARK: - all nil

    func testAllOptionalSignalsUnavailableStaysOKWithReasons() {
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals())
        XCTAssertEqual(verdict, .ok)
        XCTAssertEqual(reasons.count, 3)
        XCTAssertTrue(reasons.contains { $0.contains("Сверка повторов недоступна") })
        XCTAssertTrue(reasons.contains { $0.contains("Самопроверка недоступна") })
        XCTAssertTrue(reasons.contains { $0.contains("Оценка уверенности недоступна") })
    }
}
