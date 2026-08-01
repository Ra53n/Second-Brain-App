// TuningChatSessionStatsTests.swift — задача 86: агрегаты по сообщениям чата тюнинга.
// Таблица случаев: пусто, без отчётов, смешанные вердикты, наценка latency, разрез
// «с доп. вызовами / без».

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
}
