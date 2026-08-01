// ConfidencePipeline.swift — тонкий оркестратор оценки уверенности (задача 85):
// send → constraint (ранний FAIL) → redundancy → scoring → self-check → редьюсер.
// Решения — только в чистом ядре (ConfidenceChecks/RedundancyComparer/ConfidenceVerdict);
// здесь — сеть, замер latency/токенов, счётчик вызовов.
//
// Отклонение от бюллетеня задачи: `redundancyCount` — общее число полных ответов
// (включая основной), как в «Допущения»: «Redundancy = 3 полных ответа». При
// redundancyCount=3 итог — 1 (основной) + 2 (redundancy) + 1 (scoring) + 1 (self-check)
// = 5 сетевых вызовов, не 6 — совпадает с текстом corner-кейсов, не с числом из
// бюллетеня, которое им противоречит.

import Foundation

struct ConfidencePipeline {
    let provider: ChatProvider
    let settings: ChatSettings
    let redundancyCount: Int

    init(provider: ChatProvider, settings: ChatSettings, redundancyCount: Int = 3) {
        self.provider = provider
        self.settings = settings
        self.redundancyCount = redundancyCount
    }

    func run(system: String, transcript: String, reference: String?,
             progress: @escaping (String) -> Void = { _ in }
    ) async throws -> (answerRaw: String, report: ConfidenceReport) {
        let messages: [ChatMessageDTO] = [
            ChatMessageDTO(role: .system, content: system),
            ChatMessageDTO(role: .user, content: transcript)
        ]

        let primaryStart = Date()
        let primary = try await provider.send(messages, settings: settings)
        let primaryLatency = Date().timeIntervalSince(primaryStart)
        try Task.checkCancellation()

        var totalLatency = primaryLatency
        var promptTokens = primary.usage?.promptTokens ?? 0
        var completionTokens = primary.usage?.completionTokens ?? 0
        var extraCalls = 0

        let constraintChecks: [ConfidenceCheck] = reference.map {
            ConfidenceChecks.referenceBased(raw: primary.text, reference: $0, transcript: transcript)
        } ?? ConfidenceChecks.referenceFree(raw: primary.text, transcript: transcript)

        guard !hasHardFailure(constraintChecks) else {
            let signals = ConfidenceSignals(constraintChecks: constraintChecks)
            let (verdict, reasons) = ConfidenceVerdict.reduce(signals)
            let metrics = ConfidenceMetrics(totalCalls: 1, extraCalls: 0, primaryLatency: primaryLatency,
                                             totalLatency: totalLatency, promptTokens: promptTokens,
                                             completionTokens: completionTokens)
            return (primary.text, makeReport(verdict: verdict, reasons: reasons, metrics: metrics,
                                              checks: constraintChecks, redundancy: nil, scoring: nil, selfCheck: nil))
        }

        // Redundancy: остальные (redundancyCount - 1) прогона того же запроса.
        var redundancy: RedundancyAgreement?
        let extraRuns = max(redundancyCount - 1, 0)
        if extraRuns > 0 {
            var parsedAnswers: [[ActionItem]] = []
            var parseFailures = 0
            if let parsed = ActionItemsParser.parse(primary.text) {
                parsedAnswers.append(parsed)
            } else {
                parseFailures += 1
            }
            for i in 0..<extraRuns {
                try Task.checkCancellation()
                progress("Вызов \(i + 2) из \(redundancyCount)")
                let start = Date()
                let result = try await provider.send(messages, settings: settings)
                totalLatency += Date().timeIntervalSince(start)
                extraCalls += 1
                promptTokens += result.usage?.promptTokens ?? 0
                completionTokens += result.usage?.completionTokens ?? 0
                if let parsed = ActionItemsParser.parse(result.text) {
                    parsedAnswers.append(parsed)
                } else {
                    parseFailures += 1
                }
            }
            // Неспарсившийся повтор — расхождение: сравнивать нечего, доверять
            // нельзя (оркестраторное решение, не часть RedundancyComparer).
            redundancy = parseFailures > 0 ? .disagree : RedundancyComparer.compare(parsedAnswers)
        }

        try Task.checkCancellation()
        let scoringStart = Date()
        let scoringResult = try await provider.send(
            [ChatMessageDTO(role: .user, content: ConfidencePrompts.scoringPrompt(transcript: transcript, answer: primary.text))],
            settings: settings)
        totalLatency += Date().timeIntervalSince(scoringStart)
        extraCalls += 1
        promptTokens += scoringResult.usage?.promptTokens ?? 0
        completionTokens += scoringResult.usage?.completionTokens ?? 0
        let scoring = ConfidencePrompts.parseScoring(scoringResult.text)

        try Task.checkCancellation()
        let expectedCount = ActionItemsParser.parse(primary.text)?.count ?? 0
        let selfCheckStart = Date()
        let selfCheckResult = try await provider.send(
            [ChatMessageDTO(role: .user, content: ConfidencePrompts.selfCheckPrompt(transcript: transcript, answer: primary.text))],
            settings: settings)
        totalLatency += Date().timeIntervalSince(selfCheckStart)
        extraCalls += 1
        promptTokens += selfCheckResult.usage?.promptTokens ?? 0
        completionTokens += selfCheckResult.usage?.completionTokens ?? 0
        let selfCheck = ConfidencePrompts.parseSelfCheck(selfCheckResult.text, expectedCount: expectedCount)

        let signals = ConfidenceSignals(constraintChecks: constraintChecks, redundancy: redundancy,
                                         scoring: scoring, selfCheck: selfCheck)
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals)
        let metrics = ConfidenceMetrics(totalCalls: 1 + extraCalls, extraCalls: extraCalls,
                                         primaryLatency: primaryLatency, totalLatency: totalLatency,
                                         promptTokens: promptTokens, completionTokens: completionTokens)
        return (primary.text, makeReport(verdict: verdict, reasons: reasons, metrics: metrics,
                                          checks: constraintChecks, redundancy: redundancy,
                                          scoring: scoring, selfCheck: selfCheck))
    }

    private func hasHardFailure(_ checks: [ConfidenceCheck]) -> Bool {
        checks.contains { check in
            check.severity == .hard && { if case .fail = check.outcome { return true }; return false }()
        }
    }

    private func makeReport(verdict: ConfidenceVerdict, reasons: [String], metrics: ConfidenceMetrics,
                             checks: [ConfidenceCheck], redundancy: RedundancyAgreement?,
                             scoring: ScoringSignal?, selfCheck: SelfCheckSignal?) -> ConfidenceReport {
        let summaries = checks.map { check -> ConfidenceCheckSummary in
            switch check.outcome {
            case .pass: return ConfidenceCheckSummary(name: check.name, status: "pass", detail: nil)
            case let .fail(detail): return ConfidenceCheckSummary(name: check.name, status: "fail", detail: detail)
            case let .notApplicable(detail): return ConfidenceCheckSummary(name: check.name, status: "na", detail: detail)
            }
        }
        return ConfidenceReport(
            verdict: verdict, reasons: reasons, metrics: metrics, checks: summaries, redundancy: redundancy,
            scoringStatus: scoring?.status, scoringConfidence: scoring?.confidence,
            selfCheckSupportedCount: selfCheck.map { $0.supported.filter { $0 }.count },
            selfCheckTotalCount: selfCheck.map(\.supported.count),
            selfCheckMissed: selfCheck?.missed)
    }
}
