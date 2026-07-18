// ChatModels.swift — доменная модель чата (задача 12).
//
// Здесь живут: Chat (диалог с настройками), ChatMessage (сообщение с
// метриками), MessageMetrics, ChatConfiguration (переопределение
// провайдера/модели per-чат поверх роутера). Всё Codable со снисходительным
// init(from:) — паттерн моделей MA: history.json переживает любые миграции.
//
// Отличия от MA (осознанные, зафиксированы в «Результате» задачи):
//  - история ЛИНЕЙНАЯ (без дерева MsgNode/ветвления — бэклог 19);
//  - «память» модели — повторная отправка истории в каждом запросе (API
//    stateless), обрезка — окно последних N сообщений (historyWindow);
//  - стоимость не считаем (нет таблиц цен) — метрики: токены и время.

import Foundation

/// Роль сообщения. Незнакомая роль из будущих версий → .assistant (лениво).
enum ChatRole: String, Codable {
    case system, user, assistant

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChatRole(rawValue: raw) ?? .assistant
    }
}

/// Метрики ответа модели (только у сообщений ассистента).
struct MessageMetrics: Equatable, Codable {
    var promptTokens: Int?      // nil — провайдер не вернул usage
    var completionTokens: Int?
    var totalTokens: Int?
    var duration: TimeInterval  // время ответа, сек (wall-clock)
    // Кто фактически ответил (задача 29). providerName хранится намеренно:
    // это исторический факт на момент ответа, а у MessageBubble нет реестра.
    var providerID: String?
    var providerName: String?
    var model: String?

    init(promptTokens: Int? = nil,
         completionTokens: Int? = nil,
         totalTokens: Int? = nil,
         duration: TimeInterval,
         providerID: String? = nil,
         providerName: String? = nil,
         model: String? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.duration = duration
        self.providerID = providerID
        self.providerName = providerName
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens, completionTokens, totalTokens, duration
        case providerID, providerName, model
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        providerName = try c.decodeIfPresent(String.self, forKey: .providerName)
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}

/// Одно сообщение диалога.
struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: ChatRole
    var content: String
    var metrics: MessageMetrics?
    /// Источники RAG-ответа (задача 14): чанки, ушедшие в [RAG_CONTEXT].
    var sources: [RagSource]?
    /// Вызовы MCP-инструментов при генерации ответа (задача 15).
    var toolCalls: [ToolCallDisplay]?
    /// Этап FSM-прогона, породивший сообщение (задача 35): бейдж в UI +
    /// фильтр истории (промежуточные этапы не уходят в контекст следующих ходов).
    var agentState: AgentTaskState?
    /// Номер шага выполнения (0-based) и всего шагов — только для execution.
    var agentStep: Int?
    var agentTotal: Int?
    /// Итог code review (задача 37): PR, к которому относится сообщение —
    /// включает кнопку «Отправить комментарием в PR» и бейдж вердикта.
    /// Локальное ревью маркера не получает — постить некуда.
    var reviewTarget: ReviewTarget?
    /// Когда ревью отправлено комментарием в PR («Отправлено ✓» персистентно).
    var reviewPostedAt: Date?
    /// Применённые файловые операции хода (задача 39): diff по каждому
    /// файлу остаётся в истории — отчёт и воспроизводимость.
    var fileChanges: [FileChangeDisplay]?
    var createdAt: Date = Date()

    init(role: ChatRole, content: String, metrics: MessageMetrics? = nil) {
        self.role = role
        self.content = content
        self.metrics = metrics
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, metrics, sources, toolCalls, createdAt
        case agentState, agentStep, agentTotal
        case reviewTarget, reviewPostedAt
        case fileChanges
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decodeIfPresent(ChatRole.self, forKey: .role) ?? .assistant
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        metrics = try c.decodeIfPresent(MessageMetrics.self, forKey: .metrics)
        sources = try c.decodeIfPresent([RagSource].self, forKey: .sources)
        toolCalls = try c.decodeIfPresent([ToolCallDisplay].self, forKey: .toolCalls)
        agentState = try c.decodeIfPresent(AgentTaskState.self, forKey: .agentState)
        agentStep = try c.decodeIfPresent(Int.self, forKey: .agentStep)
        agentTotal = try c.decodeIfPresent(Int.self, forKey: .agentTotal)
        reviewTarget = try c.decodeIfPresent(ReviewTarget.self, forKey: .reviewTarget)
        reviewPostedAt = try c.decodeIfPresent(Date.self, forKey: .reviewPostedAt)
        fileChanges = try c.decodeIfPresent([FileChangeDisplay].self, forKey: .fileChanges)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Legacy-источник знаний (задача 31, до реестра задачи 34): бинарный выбор
/// vault|project. Оставлен только ради миграции старых конфигов чатов —
/// в init(from:) ChatConfiguration маппится в enabledKnowledgeBaseIDs.
enum KnowledgeSource: String, Codable {
    case vault, project

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KnowledgeSource(rawValue: raw) ?? .vault
    }

    /// Эквивалент в id реестра баз знаний (задача 34).
    var knowledgeBaseIDs: Set<String> {
        switch self {
        case .vault: return [KnowledgeBase.vaultID]
        case .project: return [KnowledgeBase.projectID]
        }
    }
}

/// Настройки генерации per-чат. providerID/model nil → роутер функции .chat
/// решает сам (пользователь ничего не выбирал — работает дефолт).
struct ChatConfiguration: Equatable, Codable {
    var providerID: ProviderID?
    var model: String?
    var temperature: Double = 1.0
    /// Окно истории: сколько последних сообщений уходит модели.
    var historyWindow: Int = 20

    // --- RAG (задача 14) ---
    /// Тумблер «Отвечать по базе» (persisted per-чат).
    var ragEnabled: Bool = false
    /// Включённые базы знаний из реестра (задача 34): мультивыбор в чипе
    /// «База». Пустое множество = искать негде (RAG честно молчит).
    var enabledKnowledgeBaseIDs: Set<String> = [KnowledgeBase.vaultID]
    /// RAG как инструмент (задача 34): tool-провайдер получает rag_search и
    /// сам решает, когда искать. Выключено → статическая подстановка
    /// [RAG_CONTEXT] (и стриминг ответа) как раньше.
    var ragAsTool: Bool = true
    var ragTopK: Int = 4
    /// Порог косинусной близости; 0 — выключен.
    var ragMinScore: Double = 0
    /// LLM-переранжирование кандидатов (выкл: лишние вызовы).
    var ragRerankEnabled: Bool = false
    /// Переписывание вопроса в поисковый запрос (выкл: лишний вызов).
    var ragQueryRewrite: Bool = false

    // --- MCP (задача 15) ---
    /// Включённые для этого чата MCP-серверы (как enabledMCPServerIDs в MA).
    var enabledMCPServerIDs: Set<UUID> = []

    // --- Инструменты проекта (задачи 21, 39) ---
    /// Встроенные git-инструменты проекта в этом чате (репозиторий — в настройках).
    var projectToolsEnabled: Bool = false
    /// Рабочий каталог ЭТОГО чата (задача 39): любой репозиторий/папка/vault.
    /// nil — глобальный projectRepoPath из настроек.
    var projectRootPath: String?
    /// Режим разрешений операций (задача 39): спрашивать / авто / авто-опасный.
    var permissionMode: AgentPermissionMode = .ask

    // --- FSM-прогон (задача 35) ---
    /// «Полный проход (FSM)»: planning → execution → validation → answer.
    /// false (дефолт) — «Один запрос»: прежний путь (стриминг / tool-цикл).
    var agentModeEnabled: Bool = false

    static let historyWindowRange = 4...50
    static let temperatureRange = 0.0...2.0
    static let ragTopKRange = 1...12

    init() {}

    enum CodingKeys: String, CodingKey {
        case providerID, model, temperature, historyWindow
        case ragEnabled, ragTopK, ragMinScore, ragRerankEnabled, ragQueryRewrite
        case knowledgeSource // legacy (задача 31) — только чтение при миграции
        case enabledKnowledgeBaseIDs, ragAsTool
        case enabledMCPServerIDs
        case projectToolsEnabled
        case projectRootPath, permissionMode
        case agentModeEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChatConfiguration()
        providerID = try c.decodeIfPresent(ProviderID.self, forKey: .providerID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        historyWindow = try c.decodeIfPresent(Int.self, forKey: .historyWindow) ?? d.historyWindow
        ragEnabled = try c.decodeIfPresent(Bool.self, forKey: .ragEnabled) ?? d.ragEnabled
        // Миграция задачи 34: новый ключ в приоритете; старый конфиг с
        // knowledgeSource маппится в id реестра; совсем старый — дефолт (vault).
        if let ids = try c.decodeIfPresent(Set<String>.self, forKey: .enabledKnowledgeBaseIDs) {
            enabledKnowledgeBaseIDs = ids
        } else if let legacy = try c.decodeIfPresent(KnowledgeSource.self,
                                                     forKey: .knowledgeSource) {
            enabledKnowledgeBaseIDs = legacy.knowledgeBaseIDs
        } else {
            enabledKnowledgeBaseIDs = d.enabledKnowledgeBaseIDs
        }
        ragAsTool = try c.decodeIfPresent(Bool.self, forKey: .ragAsTool) ?? d.ragAsTool
        ragTopK = try c.decodeIfPresent(Int.self, forKey: .ragTopK) ?? d.ragTopK
        ragMinScore = try c.decodeIfPresent(Double.self, forKey: .ragMinScore) ?? d.ragMinScore
        ragRerankEnabled = try c.decodeIfPresent(Bool.self, forKey: .ragRerankEnabled)
            ?? d.ragRerankEnabled
        ragQueryRewrite = try c.decodeIfPresent(Bool.self, forKey: .ragQueryRewrite)
            ?? d.ragQueryRewrite
        enabledMCPServerIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .enabledMCPServerIDs)
            ?? d.enabledMCPServerIDs
        projectToolsEnabled = try c.decodeIfPresent(Bool.self, forKey: .projectToolsEnabled)
            ?? d.projectToolsEnabled
        projectRootPath = try c.decodeIfPresent(String.self, forKey: .projectRootPath)
        permissionMode = try c.decodeIfPresent(AgentPermissionMode.self,
                                               forKey: .permissionMode) ?? d.permissionMode
        agentModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentModeEnabled)
            ?? d.agentModeEnabled
    }

    /// Ручной encode: legacy-ключ knowledgeSource больше не пишем (в CodingKeys
    /// он есть только ради чтения при миграции — синтез encode из-за него
    /// невозможен).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(providerID, forKey: .providerID)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(historyWindow, forKey: .historyWindow)
        try c.encode(ragEnabled, forKey: .ragEnabled)
        try c.encode(enabledKnowledgeBaseIDs, forKey: .enabledKnowledgeBaseIDs)
        try c.encode(ragAsTool, forKey: .ragAsTool)
        try c.encode(ragTopK, forKey: .ragTopK)
        try c.encode(ragMinScore, forKey: .ragMinScore)
        try c.encode(ragRerankEnabled, forKey: .ragRerankEnabled)
        try c.encode(ragQueryRewrite, forKey: .ragQueryRewrite)
        try c.encode(enabledMCPServerIDs, forKey: .enabledMCPServerIDs)
        try c.encode(projectToolsEnabled, forKey: .projectToolsEnabled)
        try c.encodeIfPresent(projectRootPath, forKey: .projectRootPath)
        try c.encode(permissionMode, forKey: .permissionMode)
        try c.encode(agentModeEnabled, forKey: .agentModeEnabled)
    }
}

/// Диалог. Runtime-поля (isLoading, errorText) на диск не пишутся.
struct Chat: Identifiable, Codable {
    var id = UUID()
    var title: String = "Новый чат"
    var messages: [ChatMessage] = []
    var configuration = ChatConfiguration()
    /// Контекст активного/последнего FSM-прогона (задача 35). Персистится:
    /// прогон переживает рестарт (normalize running → paused, «Продолжить»).
    var agentContext: AgentTaskContext?
    var createdAt: Date = Date()

    // Runtime (не в CodingKeys).
    var isLoading: Bool = false
    var errorText: String? = nil

    init(title: String = "Новый чат") {
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case id, title, messages, configuration, agentContext, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Новый чат"
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        configuration = try c.decodeIfPresent(ChatConfiguration.self, forKey: .configuration)
            ?? ChatConfiguration()
        agentContext = try c.decodeIfPresent(AgentTaskContext.self, forKey: .agentContext)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Короткий тайтл из первой строки сообщения (до 40 символов) — порт MA.
    static func makeTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Новый чат" }
        if trimmed.count <= 40 { return trimmed }
        return String(trimmed.prefix(40)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
