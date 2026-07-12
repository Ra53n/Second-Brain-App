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
    var promptTokens: Int?      // nil — провайдер не вернул usage (стриминг)
    var completionTokens: Int?
    var totalTokens: Int?
    var duration: TimeInterval  // время ответа, сек (wall-clock)

    init(promptTokens: Int? = nil,
         completionTokens: Int? = nil,
         totalTokens: Int? = nil,
         duration: TimeInterval) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.duration = duration
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens, completionTokens, totalTokens, duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
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
    var createdAt: Date = Date()

    init(role: ChatRole, content: String, metrics: MessageMetrics? = nil) {
        self.role = role
        self.content = content
        self.metrics = metrics
    }

    enum CodingKeys: String, CodingKey { case id, role, content, metrics, sources, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decodeIfPresent(ChatRole.self, forKey: .role) ?? .assistant
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        metrics = try c.decodeIfPresent(MessageMetrics.self, forKey: .metrics)
        sources = try c.decodeIfPresent([RagSource].self, forKey: .sources)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
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
    var ragTopK: Int = 4
    /// Порог косинусной близости; 0 — выключен.
    var ragMinScore: Double = 0
    /// LLM-переранжирование кандидатов (выкл: лишние вызовы).
    var ragRerankEnabled: Bool = false
    /// Переписывание вопроса в поисковый запрос (выкл: лишний вызов).
    var ragQueryRewrite: Bool = false

    static let historyWindowRange = 4...50
    static let temperatureRange = 0.0...2.0
    static let ragTopKRange = 1...12

    init() {}

    enum CodingKeys: String, CodingKey {
        case providerID, model, temperature, historyWindow
        case ragEnabled, ragTopK, ragMinScore, ragRerankEnabled, ragQueryRewrite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChatConfiguration()
        providerID = try c.decodeIfPresent(ProviderID.self, forKey: .providerID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        historyWindow = try c.decodeIfPresent(Int.self, forKey: .historyWindow) ?? d.historyWindow
        ragEnabled = try c.decodeIfPresent(Bool.self, forKey: .ragEnabled) ?? d.ragEnabled
        ragTopK = try c.decodeIfPresent(Int.self, forKey: .ragTopK) ?? d.ragTopK
        ragMinScore = try c.decodeIfPresent(Double.self, forKey: .ragMinScore) ?? d.ragMinScore
        ragRerankEnabled = try c.decodeIfPresent(Bool.self, forKey: .ragRerankEnabled)
            ?? d.ragRerankEnabled
        ragQueryRewrite = try c.decodeIfPresent(Bool.self, forKey: .ragQueryRewrite)
            ?? d.ragQueryRewrite
    }
}

/// Диалог. Runtime-поля (isLoading, errorText) на диск не пишутся.
struct Chat: Identifiable, Codable {
    var id = UUID()
    var title: String = "Новый чат"
    var messages: [ChatMessage] = []
    var configuration = ChatConfiguration()
    var createdAt: Date = Date()

    // Runtime (не в CodingKeys).
    var isLoading: Bool = false
    var errorText: String? = nil

    init(title: String = "Новый чат") {
        self.title = title
    }

    enum CodingKeys: String, CodingKey { case id, title, messages, configuration, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Новый чат"
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        configuration = try c.decodeIfPresent(ChatConfiguration.self, forKey: .configuration)
            ?? ChatConfiguration()
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
