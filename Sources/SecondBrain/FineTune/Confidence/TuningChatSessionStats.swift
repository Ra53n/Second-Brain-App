// TuningChatSessionStats.swift — агрегаты по сообщениям чата тюнинга (задача 86): P1
// чистая функция из истории чата в замеры домашки «День 7» — отклонено, повторные
// инференсы, latency/токены. Персистентного состояния не заводит, считается на лету.
//
// Задача 91: включение каскадной эскалации не должно визуально «удешевлять» сессию —
// стоимостные агрегаты (токены, вызовы, latency) считаются по «полной стоимости»
// сообщения: метрики показанного `report` плюс `escalation.primaryReport.metrics`
// у успешно эскалированных (дешёвая ступень, чей ответ не показан, но чей вызов был).
// Задача 95: та же логика для `.notImproved` — сильную ступень оплатили, хоть её ответ
// и не показан; полная стоимость = показанный (дешёвый) `report` + `strongReport.metrics`.
// `escalatedCount` (успешно улучшила) и `escalationNotImprovedCount` (отработала, но не
// помогла) — разные счётчики, не смешиваются с `escalationFailedCount` (failed/unavailable).

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
    var escalationNotImprovedCount: Int
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
    /// Micro-first (задача 96, термины домашки «День 10»). «Обработала micro» —
    /// ПОКАЗАННЫЙ ответ от дешёвой ступени: эскалации не было (nil/unavailable) либо
    /// сильная вызывалась, но её ответ не показан (failed/notImproved). «Ушло в
    /// fallback» — сильная модель ВЫЗЫВАЛАСЬ (succeeded/notImproved/failed).
    var microAnsweredCount: Int
    var fallbackAttemptedCount: Int
    /// Доля micro-ответов от answered (0 при пустом входе) — симметрично escalationShare.
    var microShare: Double
    /// Вызовы большой LLM: сумма totalCalls сильной ступени (succeeded — показанный
    /// отчёт, notImproved — strongReport; failed — 1: вызов был, отчёта нет).
    var strongCallsTotal: Int
    /// Latency сообщений без вызова сильной против сообщений с вызовом (полная
    /// стоимость). Оговорка: при `failed` отчёта сильной нет — её потраченное время в
    /// полную стоимость не входит, среднее каскада на таких сообщениях занижено.
    /// nil при пустой группе.
    var avgTotalLatencyMicroOnly: TimeInterval?
    var avgTotalLatencyWithFallback: TimeInterval?

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

        // Полная стоимость сообщения: показанный отчёт + оплаченная, но не показанная
        // ступень (дешёвая при успехе — её ответ не показан; сильная при notImproved —
        // её ответ не показан). primaryLatency сообщения — это primaryLatency ПЕРВОГО
        // реального вызова модели, totalLatency — сумма обеих ступеней.
        let fullMetrics: [ConfidenceMetrics] = entries.map { entry in
            let extra: ConfidenceMetrics?
            switch entry.escalation?.status {
            case .succeeded: extra = entry.escalation?.primaryReport?.metrics
            case .notImproved: extra = entry.escalation?.strongReport?.metrics
            default: extra = nil
            }
            guard let extra else { return entry.report.metrics }
            return ConfidenceMetrics(
                totalCalls: entry.report.metrics.totalCalls + extra.totalCalls,
                extraCalls: entry.report.metrics.extraCalls + extra.extraCalls,
                primaryLatency: entry.escalation?.status == .succeeded ? extra.primaryLatency : entry.report.metrics.primaryLatency,
                totalLatency: entry.report.metrics.totalLatency + extra.totalLatency,
                promptTokens: entry.report.metrics.promptTokens + extra.promptTokens,
                completionTokens: entry.report.metrics.completionTokens + extra.completionTokens)
        }

        let withExtra = fullMetrics.filter { $0.extraCalls > 0 }.map(\.totalLatency)
        let withoutExtra = fullMetrics.filter { $0.extraCalls == 0 }.map(\.totalLatency)
        let avgPrimaryLatency = average(fullMetrics.map(\.primaryLatency))
        let avgTotalLatency = average(fullMetrics.map(\.totalLatency))

        let succeededReports = entries.filter { $0.escalation?.status == .succeeded }.map(\.report)
        let notImprovedStrongReports = entries.compactMap { entry -> ConfidenceReport? in
            guard entry.escalation?.status == .notImproved else { return nil }
            return entry.escalation?.strongReport
        }
        let failedCount = entries.filter { $0.escalation?.status == .failed || $0.escalation?.status == .unavailable }.count

        let stagedReports = reports.filter { $0.stages != nil }
        let monoReports = reports.filter { $0.stages == nil }
        let stagedLatencies = stagedReports.map { $0.metrics.totalLatency }
        let monoLatencies = monoReports.map { $0.metrics.totalLatency }

        // Micro-first: разрез по факту ВЫЗОВА сильной модели, не по показанному ответу.
        let fallbackStatuses: Set<EscalationStatus> = [.succeeded, .notImproved, .failed]
        let pairs = Array(zip(entries, fullMetrics))
        let withFallback = pairs.filter { entry, _ in
            entry.escalation.map { fallbackStatuses.contains($0.status) } ?? false
        }
        let microOnly = pairs.filter { entry, _ in
            !(entry.escalation.map { fallbackStatuses.contains($0.status) } ?? false)
        }
        let strongCallsTotal = withFallback.reduce(0) { sum, pair in
            switch pair.0.escalation?.status {
            case .succeeded: return sum + pair.0.report.metrics.totalCalls
            case .notImproved: return sum + (pair.0.escalation?.strongReport?.metrics.totalCalls ?? 1)
            default: return sum + 1
            }
        }

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
            escalationNotImprovedCount: notImprovedStrongReports.count,
            escalationShare: reports.isEmpty ? 0 : Double(succeededReports.count) / Double(reports.count),
            escalationAddedLatency: (succeededReports + notImprovedStrongReports).reduce(0) { $0 + $1.metrics.totalLatency },
            escalationPromptTokens: (succeededReports + notImprovedStrongReports).reduce(0) { $0 + $1.metrics.promptTokens },
            escalationCompletionTokens: (succeededReports + notImprovedStrongReports).reduce(0) { $0 + $1.metrics.completionTokens },
            stagedAnswered: stagedReports.count,
            stagedOK: stagedReports.filter { $0.verdict == .ok }.count,
            monoOK: monoReports.filter { $0.verdict == .ok }.count,
            avgTotalLatencyStaged: stagedLatencies.isEmpty ? nil : average(stagedLatencies),
            avgTotalLatencyMono: monoLatencies.isEmpty ? nil : average(monoLatencies),
            microAnsweredCount: entries.filter { $0.escalation?.status != .succeeded }.count,
            fallbackAttemptedCount: withFallback.count,
            microShare: reports.isEmpty ? 0
                : Double(entries.filter { $0.escalation?.status != .succeeded }.count) / Double(reports.count),
            strongCallsTotal: strongCallsTotal,
            avgTotalLatencyMicroOnly: microOnly.isEmpty ? nil : average(microOnly.map(\.1.totalLatency)),
            avgTotalLatencyWithFallback: withFallback.isEmpty ? nil : average(withFallback.map(\.1.totalLatency)))
    }

    private static func average(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
