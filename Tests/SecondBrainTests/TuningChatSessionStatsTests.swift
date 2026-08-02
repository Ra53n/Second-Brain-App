// TuningChatSessionStatsTests.swift — задача 86: агрегаты по сообщениям чата тюнинга.
// Таблица случаев: пусто, без отчётов, смешанные вердикты, наценка latency, разрез
// «с доп. вызовами / без». Задача 91: escalatedCount/escalationFailedCount/share/added
// latency/tokens, «полная стоимость» succeeded включает обе ступени, failed/unavailable —
// только показанную, регрессия на сообщениях без escalation.
// Задача 94: сравнение моно/мульти — stagedAnswered/stagedOK/monoOK, раздельные средние
// latency по `report.stages != nil`, только моно/только мульти — противоположный набор nil.
// Задача 95: escalationNotImprovedCount отдельно от escalatedCount/escalationFailedCount,
// «полная стоимость» notImproved включает strongReport.metrics, смесь трёх исходов.

import XCTest
@testable import SecondBrain

final class TuningChatSessionStatsTests: XCTestCase {

    private func message(verdict: ConfidenceVerdict, extraCalls: Int, primaryLatency: TimeInterval,
                          totalLatency: TimeInterval, promptTokens: Int = 0, completionTokens: Int = 0) -> TuningChatMessage {
        let metrics = ConfidenceMetrics(totalCalls: 1 + extraCalls, extraCalls: extraCalls,
                                         primaryLatency: primaryLatency, totalLatency: totalLatency,
                                         promptTokens: promptTokens, completionTokens: completionTokens)
        let report = ConfidenceReport(verdict: verdict, reasons: [], metrics: metrics, checks: [])
        return TuningChatMessage(role: "assistant", content: "{}", report: report)
    }

    func testEmptyMessagesGivesNil() {
        XCTAssertNil(TuningChatSessionStats.compute(messages: []))
    }

    func testMessagesWithoutAnyReportGivesNil() {
        let messages = [
            TuningChatMessage(role: "user", content: "фрагмент"),
            TuningChatMessage(role: "assistant", content: "ошибка сети"),
        ]
        XCTAssertNil(TuningChatSessionStats.compute(messages: messages))
    }

    func testUserMessagesDoNotCountTowardAnswered() {
        let messages = [
            TuningChatMessage(role: "user", content: "фрагмент"),
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1),
        ]
        let stats = TuningChatSessionStats.compute(messages: messages)
        XCTAssertEqual(stats?.answered, 1)
    }

    func testMixedVerdictsCountEachBucket() throws {
        let messages = [
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1),
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1),
            message(verdict: .unsure, extraCalls: 2, primaryLatency: 1, totalLatency: 3),
            message(verdict: .fail, extraCalls: 4, primaryLatency: 1, totalLatency: 5),
        ]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.answered, 4)
        XCTAssertEqual(stats.ok, 2)
        XCTAssertEqual(stats.unsure, 1)
        XCTAssertEqual(stats.rejected, 1)
        XCTAssertEqual(stats.needingReinference, 2, "extraCalls > 0 — 2 сообщения")
        XCTAssertEqual(stats.extraCallsTotal, 6)
    }

    func testLatencyFactorIsMeanTotalOverMeanPrimary() throws {
        let messages = [
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1),
            message(verdict: .ok, extraCalls: 4, primaryLatency: 1, totalLatency: 3),
        ]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.avgPrimaryLatency, 1, accuracy: 0.0001)
        XCTAssertEqual(stats.avgTotalLatency, 2, accuracy: 0.0001)
        XCTAssertEqual(stats.latencyFactor, 2, accuracy: 0.0001)
    }

    func testLatencyFactorFallsBackToOneWhenPrimaryIsZero() throws {
        let messages = [message(verdict: .ok, extraCalls: 0, primaryLatency: 0, totalLatency: 0)]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.latencyFactor, 1.0)
    }

    func testSplitByExtraCallsSeparatesAverages() throws {
        let messages = [
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1),
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 3),
            message(verdict: .ok, extraCalls: 4, primaryLatency: 1, totalLatency: 5),
        ]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(try XCTUnwrap(stats.avgLatencyWithoutExtraCalls), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(stats.avgLatencyWithExtraCalls), 5, accuracy: 0.0001)
    }

    func testSplitByExtraCallsIsNilWhenOneGroupIsEmpty() throws {
        let messages = [message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1)]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertNil(stats.avgLatencyWithExtraCalls)
        XCTAssertEqual(stats.avgLatencyWithoutExtraCalls, 1)
    }

    func testTokensSumAcrossMessages() throws {
        let messages = [
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1, promptTokens: 100, completionTokens: 20),
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1, promptTokens: 50, completionTokens: 10),
        ]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.promptTokens, 150)
        XCTAssertEqual(stats.completionTokens, 30)
    }

    // MARK: - Задача 91: каскадная эскалация

    /// Сообщение без `escalation` (не тронуто новой логикой) даёт нулевые эскалационные
    /// поля — регрессия против до-91 поведения.
    func testMessagesWithoutEscalationGiveZeroEscalationFields() throws {
        let messages = [
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1, promptTokens: 100, completionTokens: 20),
            message(verdict: .unsure, extraCalls: 0, primaryLatency: 1, totalLatency: 1),
        ]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.escalatedCount, 0)
        XCTAssertEqual(stats.escalationFailedCount, 0)
        XCTAssertEqual(stats.escalationShare, 0)
        XCTAssertEqual(stats.escalationAddedLatency, 0)
        XCTAssertEqual(stats.escalationPromptTokens, 0)
        XCTAssertEqual(stats.escalationCompletionTokens, 0)
        // Регрессия: агрегаты по «полной стоимости» без эскалации совпадают с
        // report.metrics — как в старом поведении до задачи 91.
        XCTAssertEqual(stats.promptTokens, 100)
        XCTAssertEqual(stats.completionTokens, 20)
    }

    private func escalatedMessage(status: EscalationStatus, cheapPromptTokens: Int = 40,
                                   cheapCompletionTokens: Int = 8, cheapTotalLatency: TimeInterval = 2,
                                   strongPromptTokens: Int = 100, strongCompletionTokens: Int = 20,
                                   strongTotalLatency: TimeInterval = 5) -> TuningChatMessage {
        let cheapMetrics = ConfidenceMetrics(totalCalls: 1, extraCalls: 0, primaryLatency: cheapTotalLatency,
                                              totalLatency: cheapTotalLatency, promptTokens: cheapPromptTokens,
                                              completionTokens: cheapCompletionTokens)
        let cheapReport = ConfidenceReport(verdict: .unsure, reasons: [], metrics: cheapMetrics, checks: [])
        let strongMetrics = ConfidenceMetrics(totalCalls: 1, extraCalls: 0, primaryLatency: strongTotalLatency,
                                               totalLatency: strongTotalLatency, promptTokens: strongPromptTokens,
                                               completionTokens: strongCompletionTokens)
        let shownVerdict: ConfidenceVerdict = status == .succeeded ? .ok : .unsure
        let shownReport = status == .succeeded
            ? ConfidenceReport(verdict: shownVerdict, reasons: [], metrics: strongMetrics, checks: [])
            : cheapReport
        let strongReportForRecord = ConfidenceReport(verdict: .fail, reasons: [], metrics: strongMetrics, checks: [])
        let escalation = EscalationRecord(status: status, trigger: .unsure, providerID: "openai", model: "gpt-5",
                                           failureReason: status == .succeeded || status == .notImproved ? nil : "причина",
                                           primaryReport: status == .succeeded ? cheapReport : nil,
                                           strongReport: status == .notImproved ? strongReportForRecord : nil)
        return TuningChatMessage(role: "assistant", content: "{}", report: shownReport, escalation: escalation)
    }

    func testSucceededEscalationCountsTowardEscalatedAndShareAndAddedCost() throws {
        let messages = [
            escalatedMessage(status: .succeeded),
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1),
        ]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.escalatedCount, 1)
        XCTAssertEqual(stats.escalationFailedCount, 0)
        XCTAssertEqual(stats.escalationShare, 0.5, accuracy: 0.0001)
        XCTAssertEqual(stats.escalationAddedLatency, 5, "added latency — сумма показанного (сильного) отчёта")
        XCTAssertEqual(stats.escalationPromptTokens, 100)
        XCTAssertEqual(stats.escalationCompletionTokens, 20)
    }

    func testFailedEscalationCountsTowardFailedNotEscalated() throws {
        let messages = [escalatedMessage(status: .failed)]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.escalatedCount, 0)
        XCTAssertEqual(stats.escalationFailedCount, 1)
        XCTAssertEqual(stats.escalationShare, 0)
    }

    func testUnavailableEscalationCountsTowardFailedNotEscalated() throws {
        let messages = [escalatedMessage(status: .unavailable)]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.escalatedCount, 0)
        XCTAssertEqual(stats.escalationFailedCount, 1)
    }

    /// Полная стоимость сессии (promptTokens/completionTokens/latency) у успешной
    /// эскалации включает и дешёвую (`primaryReport.metrics`), и сильную (`report.metrics`)
    /// ступень — не только показанный ответ.
    func testFullCostIncludesBothPrimaryAndStrongMetricsForSucceededEscalation() throws {
        let messages = [escalatedMessage(status: .succeeded, cheapPromptTokens: 40, cheapCompletionTokens: 8,
                                          cheapTotalLatency: 2, strongPromptTokens: 100, strongCompletionTokens: 20,
                                          strongTotalLatency: 5)]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.promptTokens, 140, "40 (дешёвая) + 100 (сильная)")
        XCTAssertEqual(stats.completionTokens, 28, "8 (дешёвая) + 20 (сильная)")
        XCTAssertEqual(stats.avgTotalLatency, 7, accuracy: 0.0001, "2 (дешёвая) + 5 (сильная)")
        XCTAssertEqual(stats.avgPrimaryLatency, 2, accuracy: 0.0001,
                       "primaryLatency сообщения — реальный первый вызов (дешёвая ступень)")
    }

    /// Неудачная/недоступная эскалация не имеет второй ступени по-настоящему выполненной —
    /// полная стоимость равна стоимости показанного (дешёвого) отчёта, без задвоения.
    func testFullCostForFailedEscalationEqualsCheapReportOnly() throws {
        let messages = [escalatedMessage(status: .failed, cheapPromptTokens: 40, cheapCompletionTokens: 8,
                                          cheapTotalLatency: 2)]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.promptTokens, 40)
        XCTAssertEqual(stats.completionTokens, 8)
        XCTAssertEqual(stats.avgTotalLatency, 2, accuracy: 0.0001)
    }

    // MARK: - Задача 95: вердикт-осознанная эскалация (notImproved)

    /// `notImproved` — свой счётчик, не смешивается ни с `escalatedCount` (только
    /// успешно улучшившие), ни с `escalationFailedCount` (только failed/unavailable).
    func testNotImprovedEscalationHasOwnCounterSeparateFromEscalatedAndFailed() throws {
        let messages = [escalatedMessage(status: .notImproved)]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.escalationNotImprovedCount, 1)
        XCTAssertEqual(stats.escalatedCount, 0, "notImproved не улучшила — не succeeded")
        XCTAssertEqual(stats.escalationFailedCount, 0, "эскалация отработала, это не неудача")
    }

    /// Сильную ступень оплатили, даже если её ответ не показан — полная стоимость
    /// сессии включает `strongReport.metrics` вдобавок к показанному (дешёвому) отчёту.
    func testFullCostForNotImprovedEscalationIncludesStrongReportMetrics() throws {
        let messages = [escalatedMessage(status: .notImproved, cheapPromptTokens: 40, cheapCompletionTokens: 8,
                                          cheapTotalLatency: 2, strongPromptTokens: 100, strongCompletionTokens: 20,
                                          strongTotalLatency: 5)]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.promptTokens, 140, "40 (дешёвая, показана) + 100 (сильная, оплачена)")
        XCTAssertEqual(stats.completionTokens, 28, "8 (дешёвая) + 20 (сильная)")
        XCTAssertEqual(stats.avgTotalLatency, 7, accuracy: 0.0001, "2 (дешёвая) + 5 (сильная)")
        XCTAssertEqual(stats.avgPrimaryLatency, 2, accuracy: 0.0001, "primaryLatency — показанный (дешёвый) ответ")
        XCTAssertEqual(stats.escalationAddedLatency, 5, "стоимость эскалации — сильная ступень, хоть и не показана")
        XCTAssertEqual(stats.escalationPromptTokens, 100)
        XCTAssertEqual(stats.escalationCompletionTokens, 20)
    }

    /// Смесь всех трёх исходов эскалации в одной сессии — счётчики не текут друг в друга,
    /// «полная стоимость» суммирует оплаченные ступени каждого сообщения независимо.
    func testMixOfSucceededNotImprovedAndFailedEscalationsInOneSession() throws {
        let messages = [
            escalatedMessage(status: .succeeded, cheapPromptTokens: 10, cheapCompletionTokens: 2, cheapTotalLatency: 1,
                              strongPromptTokens: 20, strongCompletionTokens: 4, strongTotalLatency: 2),
            escalatedMessage(status: .notImproved, cheapPromptTokens: 30, cheapCompletionTokens: 6, cheapTotalLatency: 3,
                              strongPromptTokens: 40, strongCompletionTokens: 8, strongTotalLatency: 4),
            escalatedMessage(status: .failed, cheapPromptTokens: 50, cheapCompletionTokens: 10, cheapTotalLatency: 5),
        ]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.escalatedCount, 1)
        XCTAssertEqual(stats.escalationNotImprovedCount, 1)
        XCTAssertEqual(stats.escalationFailedCount, 1)
        // Полная стоимость каждого сообщения — обе ступени (показанная + оплаченная):
        // succeeded (10+20 ток, latency 1+2), notImproved (30+40 ток, latency 3+4),
        // failed — только дешёвая (50 ток, latency 5).
        XCTAssertEqual(stats.promptTokens, (10 + 20) + (30 + 40) + 50)
        XCTAssertEqual(stats.completionTokens, (2 + 4) + (6 + 8) + 10)
        XCTAssertEqual(stats.avgTotalLatency, ((1 + 2) + (3 + 4) + 5) / 3.0, accuracy: 0.0001)
    }

    // MARK: - Задача 94: сравнение моно/мульти (stages)

    private func stagedMessage(verdict: ConfidenceVerdict, totalLatency: TimeInterval) -> TuningChatMessage {
        let metrics = ConfidenceMetrics(totalCalls: 4, extraCalls: 0, primaryLatency: totalLatency, totalLatency: totalLatency)
        let stages = (0..<4).map { StageMetric(name: "S\($0)", latency: totalLatency / 4, promptTokens: 0,
                                                completionTokens: 0, parseOk: true) }
        let report = ConfidenceReport(verdict: verdict, reasons: [], metrics: metrics, checks: [], stages: stages)
        return TuningChatMessage(role: "assistant", content: "{}", report: report)
    }

    func testStagedAndMonoMixTracksSeparateCountsAndAverages() throws {
        let messages = [
            stagedMessage(verdict: .ok, totalLatency: 4),
            stagedMessage(verdict: .unsure, totalLatency: 6),
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1),
            message(verdict: .fail, extraCalls: 0, primaryLatency: 1, totalLatency: 3),
        ]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.answered, 4, "регрессия — общий счётчик не меняется по режиму")
        XCTAssertEqual(stats.stagedAnswered, 2)
        XCTAssertEqual(stats.stagedOK, 1)
        XCTAssertEqual(stats.monoOK, 1)
        XCTAssertEqual(try XCTUnwrap(stats.avgTotalLatencyStaged), 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(stats.avgTotalLatencyMono), 2, accuracy: 0.0001)
    }

    func testOnlyMonoMessagesGivesZeroStagedCountsAndNilStagedAverage() throws {
        let messages = [
            message(verdict: .ok, extraCalls: 0, primaryLatency: 1, totalLatency: 1),
            message(verdict: .fail, extraCalls: 0, primaryLatency: 1, totalLatency: 3),
        ]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.stagedAnswered, 0)
        XCTAssertEqual(stats.stagedOK, 0)
        XCTAssertNil(stats.avgTotalLatencyStaged)
        XCTAssertEqual(stats.monoOK, 1)
        XCTAssertEqual(try XCTUnwrap(stats.avgTotalLatencyMono), 2, accuracy: 0.0001)
    }

    func testOnlyStagedMessagesGivesZeroMonoOKAndNilMonoAverage() throws {
        let messages = [stagedMessage(verdict: .ok, totalLatency: 4), stagedMessage(verdict: .ok, totalLatency: 6)]
        let stats = try XCTUnwrap(TuningChatSessionStats.compute(messages: messages))
        XCTAssertEqual(stats.stagedAnswered, 2)
        XCTAssertEqual(stats.stagedOK, 2)
        XCTAssertEqual(try XCTUnwrap(stats.avgTotalLatencyStaged), 5, accuracy: 0.0001)
        XCTAssertEqual(stats.monoOK, 0)
        XCTAssertNil(stats.avgTotalLatencyMono)
    }
}
