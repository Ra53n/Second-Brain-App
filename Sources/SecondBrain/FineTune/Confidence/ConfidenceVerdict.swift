// ConfidenceVerdict.swift — редьюсер сигналов уверенности в вердикт (задача 85).

import Foundation

enum ConfidenceVerdict: String, Codable {
    case ok, unsure, fail

    /// Синтезированный декодер `RawRepresentable` бросает на незнакомой строке — тест
    /// на «значение из будущего» это ловил при чтении старого `finetune-chat.json`.
    /// Незнакомое значение → `.unsure`, тот же безопасный дефолт, что и у отсутствующего
    /// поля в `ConfidenceReport.init(from:)`; текст причин из `reasons` не теряется.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConfidenceVerdict(rawValue: raw) ?? .unsure
    }
}

struct ConfidenceMetrics: Equatable, Codable {
    var totalCalls: Int
    var extraCalls: Int
    var primaryLatency: TimeInterval
    var totalLatency: TimeInterval
    var promptTokens: Int
    var completionTokens: Int

    init(totalCalls: Int = 0, extraCalls: Int = 0, primaryLatency: TimeInterval = 0,
         totalLatency: TimeInterval = 0, promptTokens: Int = 0, completionTokens: Int = 0) {
        self.totalCalls = totalCalls
        self.extraCalls = extraCalls
        self.primaryLatency = primaryLatency
        self.totalLatency = totalLatency
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCalls = try container.decodeIfPresent(Int.self, forKey: .totalCalls) ?? 0
        extraCalls = try container.decodeIfPresent(Int.self, forKey: .extraCalls) ?? 0
        primaryLatency = try container.decodeIfPresent(TimeInterval.self, forKey: .primaryLatency) ?? 0
        totalLatency = try container.decodeIfPresent(TimeInterval.self, forKey: .totalLatency) ?? 0
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
    }
}

/// Вход редьюсера — сигналы четырёх подходов; `nil` у scoring/self-check/redundancy —
/// «недоступен» (толерантные парсеры не разобрали ответ модели), не провал.
struct ConfidenceSignals {
    let constraintChecks: [ConfidenceCheck]
    let redundancy: RedundancyAgreement?
    let scoring: ScoringSignal?
    let selfCheck: SelfCheckSignal?
    /// Имена промежуточных (не финальных) стадий, чей compact-ответ не распарсился
    /// (задача 94) — финальная стадия и так проверяется constraint'ом, двойного
    /// наказания нет.
    let stageParseFailures: [String]
    /// Задача 97: вырожденный `{}` нормализован в пустой список — вердикт не лучше
    /// UNSURE с причиной (семантика ясна, но формат модель нарушила).
    let formatNormalized: Bool
    /// Задача 97: «…недоступна» в reasons — только для ВКЛЮЧЁННОГО, но не давшего
    /// сигнала подхода. nil-сигнал выключенного тумблера — не новость (живой пример:
    /// отчёт ступени эскалации с принудительно выключенными повторами выглядел
    /// сломанным). Дефолты true сохраняют поведение прямых вызовов reduce.
    let redundancyEnabled: Bool
    let scoringEnabled: Bool
    let selfCheckEnabled: Bool

    init(constraintChecks: [ConfidenceCheck], redundancy: RedundancyAgreement? = nil,
         scoring: ScoringSignal? = nil, selfCheck: SelfCheckSignal? = nil,
         stageParseFailures: [String] = [], formatNormalized: Bool = false,
         redundancyEnabled: Bool = true, scoringEnabled: Bool = true, selfCheckEnabled: Bool = true) {
        self.constraintChecks = constraintChecks
        self.redundancy = redundancy
        self.scoring = scoring
        self.selfCheck = selfCheck
        self.stageParseFailures = stageParseFailures
        self.formatNormalized = formatNormalized
        self.redundancyEnabled = redundancyEnabled
        self.scoringEnabled = scoringEnabled
        self.selfCheckEnabled = selfCheckEnabled
    }
}

/// Агрегат одной проверки для персистентности — не сырые `CheckOutcome`.
struct ConfidenceCheckSummary: Equatable, Codable {
    var name: String
    var status: String    // "pass" | "fail" | "na"
    var detail: String?

    init(name: String, status: String, detail: String?) {
        self.name = name
        self.status = status
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "na"
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }
}

struct ConfidenceReport: Equatable, Codable {
    var verdict: ConfidenceVerdict
    var reasons: [String]
    var metrics: ConfidenceMetrics
    var checks: [ConfidenceCheckSummary]
    var redundancy: RedundancyAgreement?
    var scoringStatus: String?
    var scoringConfidence: Int?
    var selfCheckSupportedCount: Int?
    var selfCheckTotalCount: Int?
    var selfCheckMissed: Bool?
    /// Разбивка по стадиям (задача 94) — `nil` у монолитного primary.
    var stages: [StageMetric]?

    init(verdict: ConfidenceVerdict, reasons: [String], metrics: ConfidenceMetrics,
         checks: [ConfidenceCheckSummary], redundancy: RedundancyAgreement? = nil,
         scoringStatus: String? = nil, scoringConfidence: Int? = nil,
         selfCheckSupportedCount: Int? = nil, selfCheckTotalCount: Int? = nil,
         selfCheckMissed: Bool? = nil, stages: [StageMetric]? = nil) {
        self.verdict = verdict
        self.reasons = reasons
        self.metrics = metrics
        self.checks = checks
        self.redundancy = redundancy
        self.scoringStatus = scoringStatus
        self.scoringConfidence = scoringConfidence
        self.selfCheckSupportedCount = selfCheckSupportedCount
        self.selfCheckTotalCount = selfCheckTotalCount
        self.selfCheckMissed = selfCheckMissed
        self.stages = stages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try container.decodeIfPresent(ConfidenceVerdict.self, forKey: .verdict) ?? .unsure
        reasons = try container.decodeIfPresent([String].self, forKey: .reasons) ?? []
        metrics = try container.decodeIfPresent(ConfidenceMetrics.self, forKey: .metrics) ?? ConfidenceMetrics()
        checks = try container.decodeIfPresent([ConfidenceCheckSummary].self, forKey: .checks) ?? []
        redundancy = try container.decodeIfPresent(RedundancyAgreement.self, forKey: .redundancy)
        scoringStatus = try container.decodeIfPresent(String.self, forKey: .scoringStatus)
        scoringConfidence = try container.decodeIfPresent(Int.self, forKey: .scoringConfidence)
        selfCheckSupportedCount = try container.decodeIfPresent(Int.self, forKey: .selfCheckSupportedCount)
        selfCheckTotalCount = try container.decodeIfPresent(Int.self, forKey: .selfCheckTotalCount)
        selfCheckMissed = try container.decodeIfPresent(Bool.self, forKey: .selfCheckMissed)
        stages = try container.decodeIfPresent([StageMetric].self, forKey: .stages)
    }
}

extension ConfidenceVerdict {
    /// Жёсткий constraint-фейл (невалидный JSON/схема/проза) завершает пайплайн FAIL сразу
    /// — дальше уже неважно, что говорят scoring/self-check/redundancy. Иначе вердикт —
    /// худший среди сигналов; недоступный сигнал (nil) не голосует, только причина в reasons.
    static func reduce(_ signals: ConfidenceSignals) -> (verdict: ConfidenceVerdict, reasons: [String]) {
        // Все подходы выключены (задача 86) — нечего оценивать, вердикт по умолчанию
        // не «ok», а честное «неизвестно»: пустые constraintChecks отличают выключенный
        // constraint от «есть проверки, но все прошли».
        guard !signals.constraintChecks.isEmpty || signals.redundancy != nil
                || signals.scoring != nil || signals.selfCheck != nil
                || !signals.stageParseFailures.isEmpty || signals.formatNormalized else {
            return (.unsure, ["ни один подход не включён"])
        }

        var reasons: [String] = []

        let hardFailures = signals.constraintChecks.filter { $0.severity == .hard && isFail($0.outcome) }
        guard hardFailures.isEmpty else {
            // Нормализация видна и при раннем FAIL — иначе пользователь видит
            // канонический текст вместо своего `{}` без объяснения.
            if signals.formatNormalized {
                reasons.append("Формат: пустой объект {} нормализован в {\"action_items\": []}")
            }
            for check in hardFailures {
                reasons.append("Провалена проверка «\(check.name)»: \(detailText(check.outcome))")
            }
            return (.fail, reasons)
        }

        var verdict: ConfidenceVerdict = .ok

        if signals.formatNormalized {
            verdict = worse(verdict, .unsure)
            reasons.append("Формат: пустой объект {} нормализован в {\"action_items\": []}")
        }

        if !signals.stageParseFailures.isEmpty {
            verdict = worse(verdict, .unsure)
            for name in signals.stageParseFailures {
                reasons.append("Стадия «\(name)»: промежуточный ответ не в формате JSON")
            }
        }

        let softFailures = signals.constraintChecks.filter { $0.severity == .warning && isFail($0.outcome) }
        if !softFailures.isEmpty {
            verdict = worse(verdict, .unsure)
            for check in softFailures {
                reasons.append("Предупреждение «\(check.name)»: \(detailText(check.outcome))")
            }
        }

        if let redundancy = signals.redundancy {
            switch redundancy {
            case .agree: break
            case .partial:
                verdict = worse(verdict, .unsure)
                reasons.append("Повторные прогоны частично разошлись")
            case .disagree:
                verdict = worse(verdict, .fail)
                reasons.append("Повторные прогоны не сошлись")
            }
        } else if signals.redundancyEnabled {
            reasons.append("Сверка повторов недоступна")
        }

        if let selfCheck = signals.selfCheck {
            let total = selfCheck.supported.count
            let unsupported = selfCheck.supported.filter { !$0 }.count
            if total > 0 {
                if Double(unsupported) / Double(total) > 0.5 {
                    verdict = worse(verdict, .fail)
                    reasons.append("Самопроверка: не подтверждено \(unsupported) из \(total) пунктов")
                } else if unsupported >= 1 {
                    verdict = worse(verdict, .unsure)
                    reasons.append("Самопроверка: не подтверждено \(unsupported) из \(total) пунктов")
                }
            }
            if selfCheck.missed {
                verdict = worse(verdict, .unsure)
                reasons.append("Самопроверка: возможно пропущенное поручение")
            }
        } else if signals.selfCheckEnabled {
            reasons.append("Самопроверка недоступна")
        }

        if let scoring = signals.scoring {
            var scoreVerdict: ConfidenceVerdict?
            if let confidence = scoring.confidence {
                scoreVerdict = confidence < 40 ? .fail : (confidence < 70 ? .unsure : .ok)
                reasons.append("Самооценка уверенности: \(confidence)")
            }
            if let status = scoring.status?.uppercased() {
                let statusVerdict: ConfidenceVerdict?
                switch status {
                case "FAIL": statusVerdict = .fail
                case "UNSURE": statusVerdict = .unsure
                case "OK": statusVerdict = .ok
                default: statusVerdict = nil
                }
                if let statusVerdict {
                    scoreVerdict = scoreVerdict.map { worse($0, statusVerdict) } ?? statusVerdict
                    reasons.append("Статус самооценки: \(status)")
                }
            }
            if let scoreVerdict { verdict = worse(verdict, scoreVerdict) }
        } else if signals.scoringEnabled {
            reasons.append("Оценка уверенности недоступна")
        }

        return (verdict, reasons)
    }

    private static func isFail(_ outcome: CheckOutcome) -> Bool {
        if case .fail = outcome { return true }
        return false
    }

    private static func detailText(_ outcome: CheckOutcome) -> String {
        switch outcome {
        case .pass: return ""
        case .fail(let text), .notApplicable(let text): return text
        }
    }

    private static func worse(_ a: ConfidenceVerdict, _ b: ConfidenceVerdict) -> ConfidenceVerdict {
        rank(a) >= rank(b) ? a : b
    }

    private static func rank(_ verdict: ConfidenceVerdict) -> Int {
        switch verdict {
        case .fail: return 2
        case .unsure: return 1
        case .ok: return 0
        }
    }
}
