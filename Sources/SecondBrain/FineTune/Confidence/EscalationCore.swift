// EscalationCore.swift — чистое ядро каскадной эскалации (задача 91): дешёвая модель
// не уверена (UNSURE/FAIL) → повтор на выбранной пользователем сильной. Инвариант:
// `report` результата — всегда отчёт ПОКАЗАННОГО ответа; дешёвый отчёт при успешной
// эскалации уезжает в `EscalationRecord.primaryReport` (без дублей — при failed/
// unavailable его не кладём, показанный ответ и так дешёвой ступени).

import Foundation

/// Сильная модель эскалации — выбор пользователя в `ProviderRegistry`.
struct EscalationTarget: Equatable, Codable {
    var providerID: ProviderID
    var model: String // пустая строка → дефолт провайдера в момент send
}

enum EscalationStatus: String, Codable {
    case succeeded, failed, unavailable

    /// Незнакомое значение «из будущего» → `.failed` (тот же приём, что ConfidenceVerdict).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EscalationStatus(rawValue: raw) ?? .failed
    }
}

struct EscalationRecord: Equatable, Codable {
    var status: EscalationStatus
    var trigger: ConfidenceVerdict // вердикт дешёвой ступени
    var providerID: String?
    var model: String?
    var failureReason: String? // P6: причина до человека
    var primaryReport: ConfidenceReport? // только при .succeeded

    init(status: EscalationStatus, trigger: ConfidenceVerdict, providerID: String? = nil,
         model: String? = nil, failureReason: String? = nil, primaryReport: ConfidenceReport? = nil) {
        self.status = status
        self.trigger = trigger
        self.providerID = providerID
        self.model = model
        self.failureReason = failureReason
        self.primaryReport = primaryReport
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(EscalationStatus.self, forKey: .status) ?? .failed
        trigger = try c.decodeIfPresent(ConfidenceVerdict.self, forKey: .trigger) ?? .unsure
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        primaryReport = try c.decodeIfPresent(ConfidenceReport.self, forKey: .primaryReport)
    }
}

enum EscalationCore {
    static func shouldEscalate(enabled: Bool, verdict: ConfidenceVerdict) -> Bool {
        enabled && (verdict == .unsure || verdict == .fail)
    }

    /// Повторы на облаке дороги — redundancy второй ступени принудительно OFF;
    /// constraint/scoring/self-check остаются как настроил пользователь.
    static func escalationPipelineConfig(from config: ConfidencePipelineConfig) -> ConfidencePipelineConfig {
        ConfidencePipelineConfig(constraintEnabled: config.constraintEnabled, redundancyEnabled: false,
                                  scoringEnabled: config.scoringEnabled, selfCheckEnabled: config.selfCheckEnabled)
    }

    enum Attempt {
        case unavailable(reason: String)
        case succeeded(answer: String, report: ConfidenceReport, providerID: String, model: String)
        case failed(reason: String, providerID: String, model: String)
    }

    /// `attempt == nil` — эскалация не запускалась (триггера не было): показан дешёвый
    /// ответ без записи. При `succeeded` показан ответ сильной модели, дешёвый отчёт
    /// уезжает в запись; при `failed`/`unavailable` показан ответ дешёвой без дублей.
    static func composeMessage(
        primaryAnswer: String, primaryReport: ConfidenceReport, attempt: Attempt?
    ) -> (content: String, report: ConfidenceReport, escalation: EscalationRecord?) {
        guard let attempt else {
            return (primaryAnswer, primaryReport, nil)
        }
        switch attempt {
        case let .unavailable(reason):
            let record = EscalationRecord(status: .unavailable, trigger: primaryReport.verdict, failureReason: reason)
            return (primaryAnswer, primaryReport, record)
        case let .succeeded(answer, report, providerID, model):
            let record = EscalationRecord(status: .succeeded, trigger: primaryReport.verdict,
                                           providerID: providerID, model: model, primaryReport: primaryReport)
            return (answer, report, record)
        case let .failed(reason, providerID, model):
            let record = EscalationRecord(status: .failed, trigger: primaryReport.verdict,
                                           providerID: providerID, model: model, failureReason: reason)
            return (primaryAnswer, primaryReport, record)
        }
    }
}
