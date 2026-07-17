// PipelineModels.swift — доменные модели пайплайнов (задача 36).
//
// Пайплайн = «триггер → input → агент → output»: TRIGGER (ручной / cron /
// новые PR на GitHub) подставляет payload в inputTemplate, AGENT — FSM-прогон
// задачи 35 либо одиночный запрос поверх destination-чата, OUTPUT — сообщения
// в этом чате + запись PipelineRun в историю. Эталон — routines в MA
// (RoutineModels.swift): те же статусы прогонов и снисходительный декод —
// pipelines.json/pipeline-runs.json переживают любые миграции.

import Foundation

/// Режим агента: полный FSM-проход (35) или одиночный запрос.
/// Незнакомое значение из будущих версий → .single (безопаснее и дешевле).
enum PipelineAgentMode: String, Codable {
    case fsm, single

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = PipelineAgentMode(rawValue: raw) ?? .single
    }
}

/// Триггер пайплайна. Codable вручную (enum с ассоциированными значениями):
/// {"type":"manual"} / {"type":"cron","expression":"0 9 * * *"} /
/// {"type":"prWatch","owner":"o","repo":"r","pollIntervalMin":5}.
/// Незнакомый type → .manual (пайплайн не потерян, просто не автозапускается).
enum PipelineTrigger: Codable, Equatable {
    case manual
    case cron(expression: String)
    case prWatch(owner: String, repo: String, pollIntervalMin: Int)

    /// Минимальный интервал опроса GitHub: без токена rate limit 60 req/ч.
    static let minPollIntervalMin = 5

    enum CodingKeys: String, CodingKey {
        case type, expression, owner, repo, pollIntervalMin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? "manual"
        switch type {
        case "cron":
            let expression = try c.decodeIfPresent(String.self, forKey: .expression) ?? ""
            self = .cron(expression: expression)
        case "prWatch":
            let owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
            let repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
            let interval = try c.decodeIfPresent(Int.self, forKey: .pollIntervalMin)
                ?? Self.minPollIntervalMin
            self = .prWatch(owner: owner, repo: repo,
                            pollIntervalMin: max(interval, Self.minPollIntervalMin))
        default:
            self = .manual
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try c.encode("manual", forKey: .type)
        case .cron(let expression):
            try c.encode("cron", forKey: .type)
            try c.encode(expression, forKey: .expression)
        case .prWatch(let owner, let repo, let pollIntervalMin):
            try c.encode("prWatch", forKey: .type)
            try c.encode(owner, forKey: .owner)
            try c.encode(repo, forKey: .repo)
            try c.encode(pollIntervalMin, forKey: .pollIntervalMin)
        }
    }

    /// Короткое описание для списка пайплайнов.
    var summary: String {
        switch self {
        case .manual: return "Ручной запуск"
        case .cron(let expression): return "Cron: \(expression)"
        case .prWatch(let owner, let repo, let interval):
            return "PR: \(owner)/\(repo), каждые \(interval) мин"
        }
    }
}

/// Конфиг пайплайна — намерение пользователя. Runtime-состояние (lastSeen PR,
/// история прогонов) живёт отдельно в PipelineStore: редактирование конфига
/// в форме не должно затирать состояние.
struct PipelineConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = "Новый пайплайн"
    var enabled: Bool = true
    var trigger: PipelineTrigger = .manual
    /// Промпт прогона; плейсхолдеры — см. PipelineTemplate.render.
    var inputTemplate: String = ""

    // --- toolSelection: ровно те поля ChatConfiguration, которыми управляет
    // пайплайн (перед прогоном переносятся в конфиг destination-чата) ---
    var projectToolsEnabled: Bool = false
    var enabledMCPServerIDs: Set<UUID> = []
    /// Базы знаний реестра (задача 34). Пусто = RAG в прогоне выключен.
    var enabledKnowledgeBaseIDs: Set<String> = []
    var agentMode: PipelineAgentMode = .fsm
    /// Переопределение провайдера/модели; nil → роутер решает сам.
    var providerID: ProviderID?
    var model: String?

    /// Чат, куда пишутся прогоны. nil → создаётся «Пайплайн: <имя>» при
    /// первом прогоне и id записывается сюда.
    var destinationChatID: UUID?
    /// Догонять один пропущенный cron-слот при старте приложения (паттерн MA).
    var catchUpOnStart: Bool = false
    var createdAt: Date = Date()

    init(name: String = "Новый пайплайн") {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, trigger, inputTemplate
        case projectToolsEnabled, enabledMCPServerIDs, enabledKnowledgeBaseIDs
        case agentMode, providerID, model
        case destinationChatID, catchUpOnStart, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PipelineConfig()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        trigger = try c.decodeIfPresent(PipelineTrigger.self, forKey: .trigger) ?? d.trigger
        inputTemplate = try c.decodeIfPresent(String.self, forKey: .inputTemplate)
            ?? d.inputTemplate
        projectToolsEnabled = try c.decodeIfPresent(Bool.self, forKey: .projectToolsEnabled)
            ?? d.projectToolsEnabled
        enabledMCPServerIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .enabledMCPServerIDs)
            ?? d.enabledMCPServerIDs
        enabledKnowledgeBaseIDs = try c.decodeIfPresent(Set<String>.self,
                                                        forKey: .enabledKnowledgeBaseIDs)
            ?? d.enabledKnowledgeBaseIDs
        agentMode = try c.decodeIfPresent(PipelineAgentMode.self, forKey: .agentMode)
            ?? d.agentMode
        providerID = try c.decodeIfPresent(ProviderID.self, forKey: .providerID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        destinationChatID = try c.decodeIfPresent(UUID.self, forKey: .destinationChatID)
        catchUpOnStart = try c.decodeIfPresent(Bool.self, forKey: .catchUpOnStart)
            ?? d.catchUpOnStart
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Статус прогона. Неизвестное значение → .error (честнее показать проблему,
/// чем прикинуться успехом). skippedOverlap и missed — разные вещи:
/// overlap = слот наступил, но предыдущий прогон ещё жив;
/// missed = слот прошёл, пока приложение не работало.
enum PipelineRunStatus: String, Codable {
    case running, ok, error, skippedOverlap, missed

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = PipelineRunStatus(rawValue: raw) ?? .error
    }

    /// Человекочитаемый бейдж для UI (палитра статусов — в PipelineViews).
    var title: String {
        switch self {
        case .running: return "выполняется"
        case .ok: return "готово"
        case .error: return "ошибка"
        case .skippedOverlap: return "пропущен (занят)"
        case .missed: return "пропущен слот"
        }
    }
}

/// Что запустило прогон. Незнакомое значение → .manual.
enum PipelineRunTrigger: String, Codable {
    case manual, cron, prWatch, catchUp

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = PipelineRunTrigger(rawValue: raw) ?? .manual
    }

    var title: String {
        switch self {
        case .manual: return "вручную"
        case .cron: return "по расписанию"
        case .prWatch: return "новый PR"
        case .catchUp: return "догон слота"
        }
    }
}

/// Запись истории прогонов. Создаётся со статусом running ДО вызова LLM и
/// финализируется после (паттерн MA runsRepo) — рестарт посреди прогона
/// оставляет след, который normalize переводит в error.
struct PipelineRun: Identifiable, Codable, Equatable {
    var id = UUID()
    var pipelineID: UUID
    var trigger: PipelineRunTrigger
    /// Текст {{trigger_payload}} (для истории; у manual/cron обычно nil).
    var payloadSummary: String?
    /// Cron-слот, ради которого прогон: дедуп тика и catch-up.
    var scheduledFor: Date?
    var startedAt: Date = Date()
    var finishedAt: Date?
    var status: PipelineRunStatus = .running
    var errorText: String?
    var destinationChatID: UUID?
    /// Итоговое сообщение прогона в destination-чате (переход из истории).
    var resultMessageID: UUID?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    init(pipelineID: UUID, trigger: PipelineRunTrigger) {
        self.pipelineID = pipelineID
        self.trigger = trigger
    }

    enum CodingKeys: String, CodingKey {
        case id, pipelineID, trigger, payloadSummary, scheduledFor
        case startedAt, finishedAt, status, errorText
        case destinationChatID, resultMessageID
        case promptTokens, completionTokens, totalTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pipelineID = try c.decodeIfPresent(UUID.self, forKey: .pipelineID) ?? UUID()
        trigger = try c.decodeIfPresent(PipelineRunTrigger.self, forKey: .trigger) ?? .manual
        payloadSummary = try c.decodeIfPresent(String.self, forKey: .payloadSummary)
        scheduledFor = try c.decodeIfPresent(Date.self, forKey: .scheduledFor)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = try c.decodeIfPresent(PipelineRunStatus.self, forKey: .status) ?? .error
        errorText = try c.decodeIfPresent(String.self, forKey: .errorText)
        destinationChatID = try c.decodeIfPresent(UUID.self, forKey: .destinationChatID)
        resultMessageID = try c.decodeIfPresent(UUID.self, forKey: .resultMessageID)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
    }
}

/// Runtime-состояние PR-watch per pipeline (персистентное). Не в PipelineConfig:
/// конфиг — намерение пользователя, а lastSeen — факт наблюдения; пересохранение
/// формы редактора не должно сбрасывать baseline (иначе ре-триггер старых PR).
struct PRWatchState: Codable, Equatable {
    var lastSeenPRNumbers: Set<Int> = []

    init(lastSeenPRNumbers: Set<Int> = []) {
        self.lastSeenPRNumbers = lastSeenPRNumbers
    }

    enum CodingKeys: String, CodingKey { case lastSeenPRNumbers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSeenPRNumbers = try c.decodeIfPresent(Set<Int>.self, forKey: .lastSeenPRNumbers) ?? []
    }
}

/// Рендер inputTemplate — чистая функция (тестируется без движка).
enum PipelineTemplate {
    /// Подстановка плейсхолдеров: {{trigger_payload}} → payload (или "", если
    /// триггер без полезной нагрузки), {{date}} → yyyy-MM-dd в заданной зоне
    /// (инъекция timeZone — для детерминизма тестов).
    static func render(_ template: String,
                       payload: String?,
                       date: Date = Date(),
                       timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return template
            .replacingOccurrences(of: "{{trigger_payload}}", with: payload ?? "")
            .replacingOccurrences(of: "{{date}}", with: formatter.string(from: date))
    }
}
