// ConfidenceVerdictReducerTests.swift — задача 85: редьюсер сигналов в вердикт.
// Таблица случаев: каждый сигнал по отдельности + комбинации + все недоступны.

import XCTest
@testable import SecondBrain

final class ConfidenceVerdictReducerTests: XCTestCase {
    private let passChecks = [ConfidenceCheck(name: "валидный JSON", outcome: .pass, severity: .hard),
                               ConfidenceCheck(name: "без прозы", outcome: .pass, severity: .hard)]

    private func signals(constraintChecks: [ConfidenceCheck]? = nil, redundancy: RedundancyAgreement? = nil,
                          scoring: ScoringSignal? = nil, selfCheck: SelfCheckSignal? = nil,
                          stageParseFailures: [String] = []) -> ConfidenceSignals {
        ConfidenceSignals(constraintChecks: constraintChecks ?? passChecks, redundancy: redundancy,
                          scoring: scoring, selfCheck: selfCheck, stageParseFailures: stageParseFailures)
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

    /// Задача 86: полностью пустой вход (все подходы выключены, а не «недоступны») —
    /// отличается от `signals()` выше тем, что даже constraintChecks пуст.
    func testEmptySignalsGivesUnsureWithApproachesDisabledReason() {
        let (verdict, reasons) = ConfidenceVerdict.reduce(ConfidenceSignals(constraintChecks: []))
        XCTAssertEqual(verdict, .unsure)
        XCTAssertEqual(reasons, ["ни один подход не включён"])
    }

    // MARK: - stageParseFailures (задача 94)

    func testNonEmptyStageParseFailuresGivesUnsureWithStageReason() {
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals(stageParseFailures: ["Говорящие"]))
        XCTAssertEqual(verdict, .unsure)
        XCTAssertTrue(reasons.contains { $0.contains("Стадия «Говорящие»") && $0.contains("не в формате JSON") })
    }

    func testMultipleStageParseFailuresEachProduceOwnReason() {
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals(stageParseFailures: ["Говорящие", "Задачи и исполнители"]))
        XCTAssertEqual(verdict, .unsure)
        XCTAssertTrue(reasons.contains { $0.contains("Стадия «Говорящие»") })
        XCTAssertTrue(reasons.contains { $0.contains("Стадия «Задачи и исполнители»") })
    }

    func testEmptyStageParseFailuresDoesNotAffectOtherwiseOKVerdict() {
        let (verdict, _) = ConfidenceVerdict.reduce(signals(
            redundancy: .agree,
            scoring: ScoringSignal(status: "OK", confidence: 90),
            selfCheck: SelfCheckSignal(supported: [true], reasons: [""], missed: false),
            stageParseFailures: []))
        XCTAssertEqual(verdict, .ok, "пустой stageParseFailures не понижает вердикт")
    }

    /// stageParseFailures непустой понижает даже полностью благополучный прогон остальных
    /// сигналов — не выше UNSURE.
    func testStageParseFailuresCapsOtherwiseOKCombinationAtUnsure() {
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals(
            redundancy: .agree,
            scoring: ScoringSignal(status: "OK", confidence: 95),
            selfCheck: SelfCheckSignal(supported: [true, true], reasons: ["", ""], missed: false),
            stageParseFailures: ["Сроки"]))
        XCTAssertEqual(verdict, .unsure)
        XCTAssertTrue(reasons.contains { $0.contains("Стадия «Сроки»") })
    }

    /// Худший сигнал побеждает: FAIL от redundancy перекрывает UNSURE от stageParseFailures.
    func testFailSignalWinsOverStageParseFailuresUnsure() {
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals(
            redundancy: .disagree, stageParseFailures: ["Говорящие"]))
        XCTAssertEqual(verdict, .fail)
        XCTAssertTrue(reasons.contains { $0.contains("не сошлись") })
        XCTAssertTrue(reasons.contains { $0.contains("Стадия «Говорящие»") }, "причина стадии не теряется при FAIL")
    }

    /// Hard constraint fail завершает пайплайн раньше, чем успевает сработать
    /// stageParseFailures — те же гарантии, что и у остальных сигналов.
    func testHardConstraintFailWinsOverStageParseFailures() {
        let checks = [ConfidenceCheck(name: "валидный JSON", outcome: .fail("не JSON"), severity: .hard)]
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals(constraintChecks: checks,
                                                                   stageParseFailures: ["Говорящие"]))
        XCTAssertEqual(verdict, .fail)
        XCTAssertFalse(reasons.contains { $0.contains("Стадия") }, "hard fail завершает reduce до stageParseFailures")
    }

    // MARK: - Задача 97: нормализация {} и честные «недоступна»

    func testFormatNormalizedCapsVerdictAtUnsureWithReason() {
        let (verdict, reasons) = ConfidenceVerdict.reduce(
            ConfidenceSignals(constraintChecks: passChecks, formatNormalized: true))
        XCTAssertEqual(verdict, .unsure)
        XCTAssertTrue(reasons.contains { $0.contains("нормализован") })
    }

    func testFormatNormalizedDoesNotDowngradeFail() {
        let (verdict, _) = ConfidenceVerdict.reduce(
            ConfidenceSignals(constraintChecks: passChecks, redundancy: .disagree, formatNormalized: true))
        XCTAssertEqual(verdict, .fail, "worse-семантика: disagree сильнее предупреждения")
    }

    /// Все тумблеры выключены, но `{}` нормализован — это не «ни один подход не
    /// включён», а честное UNSURE с причиной нормализации.
    func testFormatNormalizedAloneBeatsNothingEnabledGuard() {
        let (verdict, reasons) = ConfidenceVerdict.reduce(
            ConfidenceSignals(constraintChecks: [], formatNormalized: true,
                              redundancyEnabled: false, scoringEnabled: false, selfCheckEnabled: false))
        XCTAssertEqual(verdict, .unsure)
        XCTAssertTrue(reasons.contains { $0.contains("нормализован") })
        XCTAssertFalse(reasons.contains("ни один подход не включён"))
    }

    /// Ранний hard-fail не глотает причину нормализации: пользователь видит, почему
    /// текст ответа не совпадает с тем, что прислала модель.
    func testHardFailKeepsNormalizationReason() {
        let hardFail = [ConfidenceCheck(name: "эталон", outcome: .fail("расхождение"), severity: .hard)]
        let (verdict, reasons) = ConfidenceVerdict.reduce(
            ConfidenceSignals(constraintChecks: hardFail, formatNormalized: true))
        XCTAssertEqual(verdict, .fail)
        XCTAssertTrue(reasons.contains { $0.contains("нормализован") })
    }

    /// «…недоступна» — только для включённого, но не давшего сигнала подхода;
    /// выключенный тумблер причин не порождает (живой случай — отчёт эскалации).
    func testUnavailableReasonsAppearOnlyForEnabledSignals() {
        let disabledAll = ConfidenceVerdict.reduce(
            ConfidenceSignals(constraintChecks: passChecks, redundancyEnabled: false,
                              scoringEnabled: false, selfCheckEnabled: false))
        XCTAssertFalse(disabledAll.reasons.contains { $0.contains("недоступна") },
                       "выключенные тумблеры молчат")

        let enabledButMissing = ConfidenceVerdict.reduce(
            ConfidenceSignals(constraintChecks: passChecks, redundancyEnabled: true,
                              scoringEnabled: true, selfCheckEnabled: true))
        XCTAssertTrue(enabledButMissing.reasons.contains("Сверка повторов недоступна"))
        XCTAssertTrue(enabledButMissing.reasons.contains("Самопроверка недоступна"))
        XCTAssertTrue(enabledButMissing.reasons.contains("Оценка уверенности недоступна"))
    }

    /// Самопроверка пустого ответа: только missed-сигнал, «не подтверждено N из N»
    /// на нуле пунктов невозможно по построению (supported пуст).
    func testEmptyAnswerSelfCheckOnlyMissedVotes() {
        let missedTrue = ConfidenceVerdict.reduce(signals(
            selfCheck: SelfCheckSignal(supported: [], reasons: [], missed: true)))
        XCTAssertEqual(missedTrue.verdict, .unsure)
        XCTAssertTrue(missedTrue.reasons.contains { $0.contains("пропущенное поручение") })

        let missedFalse = ConfidenceVerdict.reduce(signals(
            selfCheck: SelfCheckSignal(supported: [], reasons: [], missed: false)))
        XCTAssertEqual(missedFalse.verdict, .ok)
        XCTAssertFalse(missedFalse.reasons.contains { $0.contains("не подтверждено") })
    }
}
