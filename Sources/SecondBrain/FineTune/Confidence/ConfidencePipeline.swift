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
    /// Как получить primary-ответ (задача 94): один запрос `[system, transcript]` или
    /// цепочка стадий. Батч и эскалация оставляют дефолт — код их не меняется.
    let primary: PrimaryStrategy

    init(provider: ChatProvider, settings: ChatSettings, redundancyCount: Int = 3,
         config: ConfidencePipelineConfig = .default, primary: PrimaryStrategy = .monolithic) {
        self.provider = provider
        self.settings = settings
        self.redundancyCount = redundancyCount
        self.config = config
        self.primary = primary
    }

    func run(system: String, transcript: String, reference: String?,
             progress: @escaping (String) -> Void = { _ in }
    ) async throws -> (answerRaw: String, report: ConfidenceReport) {
        var primaryText: String
        let primaryLatency: TimeInterval
        let stageCount: Int
        var stageMetrics: [StageMetric]?
        var stageParseFailures: [String] = []
        var promptTokens: Int
        var completionTokens: Int
        // Redundancy повторяет ровно то, что ушло за primary-ответом: одно
        // `[system, transcript]` в монолите, отрендеренный финальный промпт в цепочке.
        let redundancyMessages: [ChatMessageDTO]

        switch primary {
        case .monolithic:
            let messages: [ChatMessageDTO] = [
                ChatMessageDTO(role: .system, content: system),
                ChatMessageDTO(role: .user, content: transcript)
            ]
            let primaryStart = Date()
            let result = try await provider.send(messages, settings: settings)
            primaryLatency = Date().timeIntervalSince(primaryStart)
            promptTokens = result.usage?.promptTokens ?? 0
            completionTokens = result.usage?.completionTokens ?? 0
            primaryText = result.text
            redundancyMessages = messages
            stageCount = 1

        case .staged(let stages) where stages.isEmpty:
            // Контракт: вызывающий фильтрует пустые стадии (effectiveStages). Guard —
            // второй рубеж: пустая цепочка вела бы к send([]) и бейджу «0 стадий».
            return try await ConfidencePipeline(provider: provider, settings: settings,
                                                 redundancyCount: redundancyCount, config: config)
                .run(system: system, transcript: transcript, reference: reference, progress: progress)

        case let .staged(stages):
            var previousOutputs: [String] = []
            var metrics: [StageMetric] = []
            var chainLatency: TimeInterval = 0
            var chainPromptTokens = 0
            var chainCompletionTokens = 0
            var lastRawText = ""
            var lastRenderedMessages: [ChatMessageDTO] = []
            let count = stages.count
            for (index, stage) in stages.enumerated() {
                try Task.checkCancellation()
                progress("Стадия \(index + 1)/\(count): \(stage.name)")
                let rendered = StagedInferenceCore.renderPrompt(stage.prompt, transcript: transcript,
                                                                  previousOutputs: previousOutputs)
                let stageMessages: [ChatMessageDTO] = [ChatMessageDTO(role: .user, content: rendered)]
                let stageStart = Date()
                let result = try await provider.send(stageMessages, settings: settings)
                let latency = Date().timeIntervalSince(stageStart)
                chainLatency += latency
                chainPromptTokens += result.usage?.promptTokens ?? 0
                chainCompletionTokens += result.usage?.completionTokens ?? 0
                let (compact, parseOk) = StagedInferenceCore.compactOutput(result.text)
                metrics.append(StageMetric(name: stage.name, latency: latency,
                                            promptTokens: result.usage?.promptTokens ?? 0,
                                            completionTokens: result.usage?.completionTokens ?? 0,
                                            parseOk: parseOk))
                // Финальная стадия и так проверяется constraint'ом — двойного наказания нет.
                if !parseOk && index < count - 1 {
                    stageParseFailures.append(stage.name)
                }
                previousOutputs.append(compact)
                lastRawText = result.text
                lastRenderedMessages = stageMessages
            }
            primaryLatency = chainLatency
            promptTokens = chainPromptTokens
            completionTokens = chainCompletionTokens
            primaryText = lastRawText
            stageMetrics = metrics
            redundancyMessages = lastRenderedMessages
            stageCount = count
        }
        try Task.checkCancellation()

        // Задача 97: вырожденный `{}` семантически = «поручений нет». Нормализуем ДО
        // проверок — hard-fail «валидный JSON» на нём нечестен; предупреждение уходит
        // в редьюсер (вердикт не лучше UNSURE), показывается нормализованный текст.
        let (normalizedPrimary, formatNormalized) = ActionItemsParser.normalizeDegenerateEmpty(primaryText)
        primaryText = normalizedPrimary

        var totalLatency = primaryLatency
        var extraCalls = 0

        let constraintChecks: [ConfidenceCheck] = config.constraintEnabled
            ? (reference.map { ConfidenceChecks.referenceBased(raw: primaryText, reference: $0, transcript: transcript) }
                ?? ConfidenceChecks.referenceFree(raw: primaryText, transcript: transcript))
            : []

        guard !config.constraintEnabled || !hasHardFailure(constraintChecks) else {
            let signals = ConfidenceSignals(constraintChecks: constraintChecks, stageParseFailures: stageParseFailures,
                                             formatNormalized: formatNormalized,
                                             redundancyEnabled: config.redundancyEnabled,
                                             scoringEnabled: config.scoringEnabled,
                                             selfCheckEnabled: config.selfCheckEnabled)
            let (verdict, reasons) = ConfidenceVerdict.reduce(signals)
            let metrics = ConfidenceMetrics(totalCalls: stageCount, extraCalls: 0, primaryLatency: primaryLatency,
                                             totalLatency: totalLatency, promptTokens: promptTokens,
                                             completionTokens: completionTokens)
            return (primaryText, makeReport(verdict: verdict, reasons: reasons, metrics: metrics,
                                             checks: constraintChecks, redundancy: nil, scoring: nil, selfCheck: nil,
                                             stages: stageMetrics))
        }

        // Redundancy: остальные (redundancyCount - 1) прогона того же (финального) запроса.
        var redundancy: RedundancyAgreement?
        let extraRuns = config.redundancyEnabled ? max(redundancyCount - 1, 0) : 0
        if extraRuns > 0 {
            var parsedAnswers: [[ActionItem]] = []
            var parseFailures = 0
            if let parsed = ActionItemsParser.parse(primaryText) {
                parsedAnswers.append(parsed)
            } else {
                parseFailures += 1
            }
            for i in 0..<extraRuns {
                try Task.checkCancellation()
                progress("Вызов \(i + 2) из \(redundancyCount)")
                let start = Date()
                let result = try await provider.send(redundancyMessages, settings: settings)
                totalLatency += Date().timeIntervalSince(start)
                extraCalls += 1
                promptTokens += result.usage?.promptTokens ?? 0
                completionTokens += result.usage?.completionTokens ?? 0
                // Повтор тоже может ответить вырожденным `{}` — та же нормализация,
                // иначе валидный пустой кейс давал бы ложный disagree.
                if let parsed = ActionItemsParser.parse(ActionItemsParser.normalizeDegenerateEmpty(result.text).text) {
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
                [ChatMessageDTO(role: .user, content: ConfidencePrompts.scoringPrompt(transcript: transcript, answer: primaryText))],
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
            let expectedCount = ActionItemsParser.parse(primaryText)?.count ?? 0
            // Задача 97: на пустом ответе per-item подтверждать нечего — отдельный
            // промпт только про пропущенные поручения (иначе модель выдумывает пункты).
            let selfCheckPrompt = expectedCount == 0
                ? ConfidencePrompts.selfCheckEmptyPrompt(transcript: transcript)
                : ConfidencePrompts.selfCheckPrompt(transcript: transcript, answer: primaryText)
            let selfCheckStart = Date()
            let selfCheckResult = try await provider.send(
                [ChatMessageDTO(role: .user, content: selfCheckPrompt)],
                settings: settings)
            totalLatency += Date().timeIntervalSince(selfCheckStart)
            extraCalls += 1
            promptTokens += selfCheckResult.usage?.promptTokens ?? 0
            completionTokens += selfCheckResult.usage?.completionTokens ?? 0
            selfCheck = ConfidencePrompts.parseSelfCheck(selfCheckResult.text, expectedCount: expectedCount)
        }

        let signals = ConfidenceSignals(constraintChecks: constraintChecks, redundancy: redundancy,
                                         scoring: scoring, selfCheck: selfCheck, stageParseFailures: stageParseFailures,
                                         formatNormalized: formatNormalized,
                                         redundancyEnabled: config.redundancyEnabled,
                                         scoringEnabled: config.scoringEnabled,
                                         selfCheckEnabled: config.selfCheckEnabled)
        let (verdict, reasons) = ConfidenceVerdict.reduce(signals)
        let metrics = ConfidenceMetrics(totalCalls: stageCount + extraCalls, extraCalls: extraCalls,
                                         primaryLatency: primaryLatency, totalLatency: totalLatency,
                                         promptTokens: promptTokens, completionTokens: completionTokens)
        return (primaryText, makeReport(verdict: verdict, reasons: reasons, metrics: metrics,
                                         checks: constraintChecks, redundancy: redundancy,
                                         scoring: scoring, selfCheck: selfCheck, stages: stageMetrics))
    }

    private func hasHardFailure(_ checks: [ConfidenceCheck]) -> Bool {
        checks.contains { check in
            check.severity == .hard && { if case .fail = check.outcome { return true }; return false }()
        }
    }

    private func makeReport(verdict: ConfidenceVerdict, reasons: [String], metrics: ConfidenceMetrics,
                             checks: [ConfidenceCheck], redundancy: RedundancyAgreement?,
                             scoring: ScoringSignal?, selfCheck: SelfCheckSignal?,
                             stages: [StageMetric]? = nil) -> ConfidenceReport {
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
            selfCheckMissed: selfCheck?.missed, stages: stages)
    }
}
