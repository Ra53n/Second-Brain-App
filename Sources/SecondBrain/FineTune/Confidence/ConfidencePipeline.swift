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

/// Какие подходы пайплайна применяются к следующему сообщению (задача 86): пользователь
/// включает/выключает их прямо в чате. Продовый дефолт — только constraint (мгновенный
/// и бесплатный); `allEnabled` — для батч-прогона (задача 85, намеренно не регулируется)
/// и для тестов, которым нужен полный прогон.
struct ConfidencePipelineConfig: Equatable, Codable {
    var constraintEnabled: Bool
    var redundancyEnabled: Bool
    var scoringEnabled: Bool
    var selfCheckEnabled: Bool

    static let `default` = ConfidencePipelineConfig(constraintEnabled: true, redundancyEnabled: false,
                                                      scoringEnabled: false, selfCheckEnabled: false)
    static let allEnabled = ConfidencePipelineConfig(constraintEnabled: true, redundancyEnabled: true,
                                                       scoringEnabled: true, selfCheckEnabled: true)

    init(constraintEnabled: Bool, redundancyEnabled: Bool, scoringEnabled: Bool, selfCheckEnabled: Bool) {
        self.constraintEnabled = constraintEnabled
        self.redundancyEnabled = redundancyEnabled
        self.scoringEnabled = scoringEnabled
        self.selfCheckEnabled = selfCheckEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        constraintEnabled = try container.decodeIfPresent(Bool.self, forKey: .constraintEnabled) ?? true
        redundancyEnabled = try container.decodeIfPresent(Bool.self, forKey: .redundancyEnabled) ?? false
        scoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .scoringEnabled) ?? false
        selfCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .selfCheckEnabled) ?? false
    }
}

struct ConfidencePipeline {
    let provider: ChatProvider
    let settings: ChatSettings
    let redundancyCount: Int
    let config: ConfidencePipelineConfig

    init(provider: ChatProvider, settings: ChatSettings, redundancyCount: Int = 3,
         config: ConfidencePipelineConfig = .default) {
        self.provider = provider
        self.settings = settings
        self.redundancyCount = redundancyCount
        self.config = config
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

        let constraintChecks: [ConfidenceCheck] = config.constraintEnabled
            ? (reference.map { ConfidenceChecks.referenceBased(raw: primary.text, reference: $0, transcript: transcript) }
                ?? ConfidenceChecks.referenceFree(raw: primary.text, transcript: transcript))
            : []

        guard !config.constraintEnabled || !hasHardFailure(constraintChecks) else {
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
        let extraRuns = config.redundancyEnabled ? max(redundancyCount - 1, 0) : 0
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

        var scoring: ScoringSignal?
        if config.scoringEnabled {
            try Task.checkCancellation()
            let scoringStart = Date()
            let scoringResult = try await provider.send(
                [ChatMessageDTO(role: .user, content: ConfidencePrompts.scoringPrompt(transcript: transcript, answer: primary.text))],
                settings: settings)
            totalLatency += Date().timeIntervalSince(scoringStart)
            extraCalls += 1
            promptTokens += scoringResult.usage?.promptTokens ?? 0
            completionTokens += scoringResult.usage?.completionTokens ?? 0
            scoring = ConfidencePrompts.parseScoring(scoringResult.text)
        }

        var selfCheck: SelfCheckSignal?
        if config.selfCheckEnabled {
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
            selfCheck = ConfidencePrompts.parseSelfCheck(selfCheckResult.text, expectedCount: expectedCount)
        }

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
