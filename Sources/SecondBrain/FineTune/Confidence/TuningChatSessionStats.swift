// TuningChatSessionStats.swift — агрегаты по сообщениям чата тюнинга (задача 86): P1
// чистая функция из истории чата в замеры домашки «День 7» — отклонено, повторные
// инференсы, latency/токены. Персистентного состояния не заводит, считается на лету.

import Foundation

struct TuningChatSessionStats: Equatable {
    var answered: Int
    var ok: Int
    var unsure: Int
    var rejected: Int
    var needingReinference: Int
    var extraCallsTotal: Int
    var avgPrimaryLatency: TimeInterval
    var avgTotalLatency: TimeInterval
    var latencyFactor: Double
    var promptTokens: Int
    var completionTokens: Int
    var avgLatencyWithExtraCalls: TimeInterval?
    var avgLatencyWithoutExtraCalls: TimeInterval?

    /// Считает по `report` сообщений ассистента; сообщения без отчёта (ошибка, ещё не
    /// снятые) в агрегаты не попадают. Пустой вход/нет отчётов → nil, панель скрыта.
    static func compute(messages: [TuningChatMessage]) -> TuningChatSessionStats? {
        let reports = messages.filter { $0.role == "assistant" }.compactMap(\.report)
        guard !reports.isEmpty else { return nil }

        let withExtra = reports.filter { $0.metrics.extraCalls > 0 }.map(\.metrics.totalLatency)
        let withoutExtra = reports.filter { $0.metrics.extraCalls == 0 }.map(\.metrics.totalLatency)
        let avgPrimaryLatency = average(reports.map(\.metrics.primaryLatency))
        let avgTotalLatency = average(reports.map(\.metrics.totalLatency))

        return TuningChatSessionStats(
            answered: reports.count,
            ok: reports.filter { $0.verdict == .ok }.count,
            unsure: reports.filter { $0.verdict == .unsure }.count,
            rejected: reports.filter { $0.verdict == .fail }.count,
            needingReinference: reports.filter { $0.metrics.extraCalls > 0 }.count,
            extraCallsTotal: reports.reduce(0) { $0 + $1.metrics.extraCalls },
            avgPrimaryLatency: avgPrimaryLatency,
            avgTotalLatency: avgTotalLatency,
            latencyFactor: avgPrimaryLatency > 0 ? avgTotalLatency / avgPrimaryLatency : 1.0,
            promptTokens: reports.reduce(0) { $0 + $1.metrics.promptTokens },
            completionTokens: reports.reduce(0) { $0 + $1.metrics.completionTokens },
            avgLatencyWithExtraCalls: withExtra.isEmpty ? nil : average(withExtra),
            avgLatencyWithoutExtraCalls: withoutExtra.isEmpty ? nil : average(withoutExtra))
    }

    private static func average(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
