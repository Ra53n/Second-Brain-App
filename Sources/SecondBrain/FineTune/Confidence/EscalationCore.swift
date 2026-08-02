// EscalationCore.swift — чистое ядро каскадной эскалации (задача 91): дешёвая модель
// не уверена (UNSURE/FAIL) → повтор на выбранной пользователем сильной. Инвариант:
// `report` результата — всегда отчёт ПОКАЗАННОГО ответа; дешёвый отчёт при успешной
// эскалации уезжает в `EscalationRecord.primaryReport` (без дублей — при failed/
// unavailable его не кладём, показанный ответ и так дешёвой ступени).
//
// Задача 95: сильная модель отвечает не хуже дешёвой (ok > unsure > fail) — по-старому
// `.succeeded`. Строго хуже (живой случай — тюн-7B выдал `{}` с hard-fail против
// валидного UNSURE 3B) → показан ответ дешёвой, `.notImproved`, отчёт сильной уезжает
// в `EscalationRecord.strongReport` (стоимость её вызова не теряется из статистики).

import Foundation

/// Разновидность цели эскалации (задача 93): `.registry` — провайдер `ProviderRegistry`
/// (как раньше), `.localTuned` — локальная тюненая модель поверх второго `mlx_lm.server`.
enum EscalationTargetKind: String, Codable {
    case registry
    case localTuned

    /// Незнакомое значение «из будущего» → `.registry`: резолв даст `.unavailable`,
    /// не краш — тот же приём, что `EscalationStatus`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EscalationTargetKind(rawValue: raw) ?? .registry
    }
}

extension ProviderID {
    /// Сентинел для `.localTuned`: не регистрируется в `ProviderRegistry` (BACKLOG 48) —
    /// эскалация резолвит его отдельной веткой ДО контакта с реестром.
    static let localTunedProviderID = ProviderID(rawValue: "mlx-local")
}

/// Сильная модель эскалации — выбор пользователя. Для `.registry` — провайдер
/// `ProviderRegistry`; для `.localTuned` — `model` это база тюна, `providerID` —
/// `localTunedProviderID`.
struct EscalationTarget: Equatable, Codable {
    var providerID: ProviderID
    var model: String // пустая строка → дефолт провайдера в момент send
    var kind: EscalationTargetKind = .registry

    init(providerID: ProviderID, model: String, kind: EscalationTargetKind = .registry) {
        self.providerID = providerID
        self.model = model
        self.kind = kind
    }

    /// Файлы эпохи 91 (без `kind`) мигрируют на `.registry` молча.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try c.decode(ProviderID.self, forKey: .providerID)
        model = try c.decode(String.self, forKey: .model)
        kind = try c.decodeIfPresent(EscalationTargetKind.self, forKey: .kind) ?? .registry
    }
}

enum EscalationStatus: String, Codable {
    case succeeded, failed, unavailable
    /// Сильная модель ответила строго хуже дешёвой (задача 95) — показан ответ дешёвой.
    case notImproved

    /// Незнакомое значение «из будущего» → `.failed` (тот же приём, что ConfidenceVerdict).
    /// Старый билд, ещё не знающий `notImproved`, деградирует так же — безопасно: показанный
    /// ответ в записи и так дешёвой ступени, только ярлык неудачи неточен.
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
    var strongReport: ConfidenceReport? // только при .notImproved — отчёт сильной, не показан

    init(status: EscalationStatus, trigger: ConfidenceVerdict, providerID: String? = nil,
         model: String? = nil, failureReason: String? = nil, primaryReport: ConfidenceReport? = nil,
         strongReport: ConfidenceReport? = nil) {
        self.status = status
        self.trigger = trigger
        self.providerID = providerID
        self.model = model
        self.failureReason = failureReason
        self.primaryReport = primaryReport
        self.strongReport = strongReport
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(EscalationStatus.self, forKey: .status) ?? .failed
        trigger = try c.decodeIfPresent(ConfidenceVerdict.self, forKey: .trigger) ?? .unsure
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        primaryReport = try c.decodeIfPresent(ConfidenceReport.self, forKey: .primaryReport)
        strongReport = try c.decodeIfPresent(ConfidenceReport.self, forKey: .strongReport)
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
    /// ответ без записи. При `succeeded` (сильная не хуже дешёвой) показан ответ сильной
    /// модели, дешёвый отчёт уезжает в запись; строго хуже → `.notImproved`, показан ответ
    /// дешёвой, отчёт сильной — в `strongReport`; при `failed`/`unavailable` показан ответ
    /// дешёвой без дублей.
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
            guard rank(report.verdict) < rank(primaryReport.verdict) else {
                let record = EscalationRecord(status: .succeeded, trigger: primaryReport.verdict,
                                               providerID: providerID, model: model, primaryReport: primaryReport)
                return (answer, report, record)
            }
            let record = EscalationRecord(status: .notImproved, trigger: primaryReport.verdict,
                                           providerID: providerID, model: model, strongReport: report)
            return (primaryAnswer, primaryReport, record)
        case let .failed(reason, providerID, model):
            let record = EscalationRecord(status: .failed, trigger: primaryReport.verdict,
                                           providerID: providerID, model: model, failureReason: reason)
            return (primaryAnswer, primaryReport, record)
        }
    }

    /// ok > unsure > fail — сравнение вердиктов при решении, показывать ли ответ
    /// сильной модели (задача 95). Приватная и локальная для ядра: не путать с
    /// одноимённым `rank` в `ConfidenceVerdict` (там наоборот, «хуже» — больше).
    private static func rank(_ verdict: ConfidenceVerdict) -> Int {
        switch verdict {
        case .ok: return 2
        case .unsure: return 1
        case .fail: return 0
        }
    }
}
