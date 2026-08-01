// TuningChatSessionStats.swift — агрегаты по сообщениям чата тюнинга (задача 86): P1
// чистая функция из истории чата в замеры домашки «День 7» — отклонено, повторные
// инференсы, latency/токены. Персистентного состояния не заводит, считается на лету.
//
// Задача 91: включение каскадной эскалации не должно визуально «удешевлять» сессию —
// стоимостные агрегаты (токены, вызовы, latency) считаются по «полной стоимости»
// сообщения: метрики показанного `report` плюс `escalation.primaryReport.metrics`
// у успешно эскалированных (дешёвая ступень, чей ответ не показан, но чей вызов был).

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
    var escalatedCount: Int
    var escalationFailedCount: Int
    var escalationShare: Double
    var escalationAddedLatency: TimeInterval
    var escalationPromptTokens: Int
    var escalationCompletionTokens: Int
    /// Сравнение моно/мульти (задача 94) — режим сообщения определяется по показанному
    /// `report.stages != nil`, latency берётся из его же `metrics.totalLatency`
    /// (не `fullMetrics`, чтобы эскалация не размывала сравнение чистого primary).
    var stagedAnswered: Int
    var stagedOK: Int
    var monoOK: Int
    var avgTotalLatencyStaged: TimeInterval?
    var avgTotalLatencyMono: TimeInterval?

    /// Считает по `report` сообщений ассистента; сообщения без отчёта (ошибка, ещё не
    /// снятые) в агрегаты не попадают. Пустой вход/нет отчётов → nil, панель скрыта.
    static func compute(messages: [TuningChatMessage]) -> TuningChatSessionStats? {
        // Пары (report, escalation) только для сообщений, у которых report есть —
        // отдельный compactMap на escalation тут же рассинхронил бы индексы с report.
        let entries: [(report: ConfidenceReport, escalation: EscalationRecord?)] = messages
            .filter { $0.role == "assistant" }
            .compactMap { message in message.report.map { (report: $0, escalation: message.escalation) } }
        guard !entries.isEmpty else { return nil }
        let reports = entries.map(\.report)

        // Полная стоимость сообщения: показанный отчёт + дешёвая ступень при успехе.
        // primaryLatency сообщения — это primaryLatency дешёвой ступени (первый реальный
        // вызов модели), totalLatency — сумма обеих ступеней.
        let fullMetrics: [ConfidenceMetrics] = entries.map { entry in
            guard let primary = entry.escalation?.primaryReport?.metrics, entry.escalation?.status == .succeeded else {
                return entry.report.metrics
            }
            return ConfidenceMetrics(
                totalCalls: entry.report.metrics.totalCalls + primary.totalCalls,
                extraCalls: entry.report.metrics.extraCalls + primary.extraCalls,
                primaryLatency: primary.primaryLatency,
                totalLatency: entry.report.metrics.totalLatency + primary.totalLatency,
                promptTokens: entry.report.metrics.promptTokens + primary.promptTokens,
                completionTokens: entry.report.metrics.completionTokens + primary.completionTokens)
        }

        let withExtra = fullMetrics.filter { $0.extraCalls > 0 }.map(\.totalLatency)
        let withoutExtra = fullMetrics.filter { $0.extraCalls == 0 }.map(\.totalLatency)
        let avgPrimaryLatency = average(fullMetrics.map(\.primaryLatency))
        let avgTotalLatency = average(fullMetrics.map(\.totalLatency))

        let succeededReports = entries.filter { $0.escalation?.status == .succeeded }.map(\.report)
        let failedCount = entries.filter { $0.escalation?.status == .failed || $0.escalation?.status == .unavailable }.count

        let stagedReports = reports.filter { $0.stages != nil }
        let monoReports = reports.filter { $0.stages == nil }
        let stagedLatencies = stagedReports.map { $0.metrics.totalLatency }
        let monoLatencies = monoReports.map { $0.metrics.totalLatency }

        return TuningChatSessionStats(
            answered: reports.count,
            ok: reports.filter { $0.verdict == .ok }.count,
            unsure: reports.filter { $0.verdict == .unsure }.count,
            rejected: reports.filter { $0.verdict == .fail }.count,
            needingReinference: fullMetrics.filter { $0.extraCalls > 0 }.count,
            extraCallsTotal: fullMetrics.reduce(0) { $0 + $1.extraCalls },
            avgPrimaryLatency: avgPrimaryLatency,
            avgTotalLatency: avgTotalLatency,
            latencyFactor: avgPrimaryLatency > 0 ? avgTotalLatency / avgPrimaryLatency : 1.0,
            promptTokens: fullMetrics.reduce(0) { $0 + $1.promptTokens },
            completionTokens: fullMetrics.reduce(0) { $0 + $1.completionTokens },
            avgLatencyWithExtraCalls: withExtra.isEmpty ? nil : average(withExtra),
            avgLatencyWithoutExtraCalls: withoutExtra.isEmpty ? nil : average(withoutExtra),
            escalatedCount: succeededReports.count,
            escalationFailedCount: failedCount,
            escalationShare: reports.isEmpty ? 0 : Double(succeededReports.count) / Double(reports.count),
            escalationAddedLatency: succeededReports.reduce(0) { $0 + $1.metrics.totalLatency },
            escalationPromptTokens: succeededReports.reduce(0) { $0 + $1.metrics.promptTokens },
            escalationCompletionTokens: succeededReports.reduce(0) { $0 + $1.metrics.completionTokens },
            stagedAnswered: stagedReports.count,
            stagedOK: stagedReports.filter { $0.verdict == .ok }.count,
            monoOK: monoReports.filter { $0.verdict == .ok }.count,
            avgTotalLatencyStaged: stagedLatencies.isEmpty ? nil : average(stagedLatencies),
            avgTotalLatencyMono: monoLatencies.isEmpty ? nil : average(monoLatencies))
    }

    private static func average(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
