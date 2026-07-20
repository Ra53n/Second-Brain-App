// OllamaModels.swift — модели Ollama: DTO, парсеры API и HTTP-клиент
// (порт LocalModelsClient/LocalModelsParsing из MA, обрезанный до Ollama).
//
// Эндпойнты: GET /api/tags (установленные), POST /api/pull (NDJSON-стрим
// прогресса скачивания), DELETE /api/delete, GET /api/version, POST /api/chat
// (чат, стрим — тоже NDJSON), POST /api/embed (эмбеддинги). Парсеры отделены
// от сети (enum OllamaParsing) и тестируются по фикстурам без сервера.

import Foundation

/// Установленная модель из /api/tags.
struct OllamaModel: Identifiable, Hashable {
    var name: String            // "qwen3:8b" — это же id для чата
    var sizeBytes: Int64?
    var quantization: String?   // "Q4_K_M"
    var parameterSize: String?  // "8.2B"
    /// capabilities из /api/tags (новые Ollama): completion/tools/embedding.
    /// nil — старый сервер без поля (считаем чат-пригодной).
    var capabilities: [String]? = nil

    var id: String { name }

    /// Пригодна для чата (задача 32): у эмбеддинг-моделей (bge-m3, nomic)
    /// нет capability completion — в пикере моделей чата им не место.
    var supportsChat: Bool {
        capabilities.map { $0.contains("completion") } ?? true
    }

    /// Пригодна для эмбеддингов: capability "embedding" (nomic, bge-m3).
    /// nil capabilities (старый сервер) — НЕ считаем эмбеддинговой: чат-модель
    /// эмбеддинги корректно не отдаёт, роутер не должен подсовывать её в embed.
    var supportsEmbedding: Bool {
        capabilities.map { $0.contains("embedding") } ?? false
    }

    /// Компактная строка метаданных: «4,7 ГБ · Q4_K_M · 8B».
    var detailLine: String? {
        var parts: [String] = []
        if let size = sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let quant = quantization, !quant.isEmpty { parts.append(quant) }
        if let params = parameterSize, !params.isEmpty { parts.append(params) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Одна строка NDJSON-стрима /api/pull.
struct OllamaPullProgress: Equatable {
    var status: String = ""     // "pulling manifest", "downloading …", "success"
    var total: Int64?
    var completed: Int64?
    var errorText: String?

    /// Доля 0…1; nil на этапах без размера (манифест/верификация).
    var fraction: Double? {
        guard let total, total > 0, let completed else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var isSuccess: Bool { status == "success" }
}

/// Рекомендуемый стартовый набор (июль 2026): компактная чат-модель и
/// эмбеддинги для RAG. Уточнять по мере выхода новых моделей.
struct RecommendedOllamaModel {
    let name: String
    let purpose: String

    static let starterPack: [RecommendedOllamaModel] = [
        RecommendedOllamaModel(name: "qwen3:8b", purpose: "чат и summary встреч"),
        RecommendedOllamaModel(name: "nomic-embed-text", purpose: "эмбеддинги для RAG (задача 13)"),
    ]
}

// MARK: - Парсеры (чистые, тестируются по фикстурам)

enum OllamaParsing {
    // /api/tags → {"models":[{"name":…,"size":…,"details":{…}}]}
    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            struct Details: Decodable {
                let quantization_level: String?
                let parameter_size: String?
            }
            let name: String
            let size: Int64?
            let details: Details?
            let capabilities: [String]?
        }
        let models: [Model]?
    }

    static func parseTags(_ data: Data) throws -> [OllamaModel] {
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return (decoded.models ?? []).map {
            OllamaModel(name: $0.name,
                        sizeBytes: $0.size,
                        quantization: $0.details?.quantization_level,
                        parameterSize: $0.details?.parameter_size,
                        capabilities: $0.capabilities)
        }
    }

    /// Одна строка стрима /api/pull → прогресс; мусор/пустая строка → nil.
    /// {"error":…} возвращается с errorText — клиент бросит ошибку.
    static func parsePullLine(_ line: String) -> OllamaPullProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        struct Line: Decodable {
            let status: String?
            let total: Int64?
            let completed: Int64?
            let error: String?
        }
        guard let decoded = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
        if decoded.status == nil && decoded.error == nil { return nil }
        return OllamaPullProgress(status: decoded.status ?? "",
                                  total: decoded.total,
                                  completed: decoded.completed,
                                  errorText: decoded.error)
    }

    // /api/chat (stream:false) → {"message":{"content":…},"prompt_eval_count":…,"eval_count":…}
    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let prompt_eval_count: Int?
        let eval_count: Int?
    }

    static func parseChatResponse(_ data: Data) throws -> ChatResult {
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let text = decoded.message?.content, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        var usage: ChatUsage?
        if let prompt = decoded.prompt_eval_count, let completion = decoded.eval_count {
            usage = ChatUsage(promptTokens: prompt,
                              completionTokens: completion,
                              totalTokens: prompt + completion)
        }
        return ChatResult(text: text, usage: usage)
    }

    /// Одна строка NDJSON-стрима /api/chat → (дельта, конец, usage).
    /// usage несёт финальная done-строка (prompt_eval_count/eval_count —
    /// зеркально parseChatResponse, задача 29). Мусорная строка → nil.
    static func parseChatStreamLine(_ line: String) -> (delta: String, done: Bool, usage: ChatUsage?)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        struct Line: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let done: Bool?
            let prompt_eval_count: Int?
            let eval_count: Int?
        }
        guard let decoded = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
        var usage: ChatUsage?
        if let prompt = decoded.prompt_eval_count, let completion = decoded.eval_count {
            usage = ChatUsage(promptTokens: prompt,
                              completionTokens: completion,
                              totalTokens: prompt + completion)
        }
        return (decoded.message?.content ?? "", decoded.done ?? false, usage)
    }

    // /api/embed → {"embeddings":[[…],[…]]}
    private struct EmbedResponse: Decodable { let embeddings: [[Float]]? }

    static func parseEmbedResponse(_ data: Data) throws -> [[Float]] {
        let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
        guard let vectors = decoded.embeddings, !vectors.isEmpty else {
            throw LLMError.emptyResponse
        }
        return vectors
    }
}

// MARK: - HTTP-клиент

/// Клиент Ollama API. Immutable struct без глобального состояния (конвенции);
/// ленивый старт сервера — забота вызывающего (OllamaProvider → OllamaManager).
struct OllamaClient {
    var baseURL: String

    /// Установленные модели: GET /api/tags.
    func installedModels() async throws -> [OllamaModel] {
        try OllamaParsing.parseTags(await get("/api/tags"))
    }

    /// Скачивание модели: POST /api/pull, NDJSON-стрим прогресса.
    /// Отмена обёртывающего Task рвёт стрим (+ checkCancellation на строке).
    func pull(model: String,
              progress: @escaping @Sendable (OllamaPullProgress) -> Void) async throws {
        guard let url = URL(string: baseURL + "/api/pull") else { throw OllamaError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Оба ключа: новые версии ждут "model", старые — "name".
        struct Body: Encodable { let model: String; let name: String; let stream: Bool }
        request.httpBody = try JSONEncoder().encode(Body(model: model, name: model, stream: true))
        // timeoutInterval — idle-таймаут МЕЖДУ байтами: многогигабайтный pull
        // безопасен, зависший CDN отвалится за 5 минут.
        request.timeoutInterval = 300

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.badStatus(code: -1, message: "нет HTTP-ответа")
        }
        guard (200...299).contains(http.statusCode) else {
            var text = ""
            for try await line in bytes.lines { text = line; break }
            throw OllamaError.badStatus(code: http.statusCode,
                                        message: text.isEmpty ? "ошибка сервера" : text)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let p = OllamaParsing.parsePullLine(line) else { continue }
            if let error = p.errorText, !error.isEmpty { throw OllamaError.pullFailed(error) }
            progress(p)
        }
    }

    /// Удаление модели: DELETE /api/delete.
    func delete(model: String) async throws {
        guard let url = URL(string: baseURL + "/api/delete") else { throw OllamaError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": model, "name": model])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.badStatus(code: -1, message: "нет HTTP-ответа")
        }
        if http.statusCode == 404 { throw OllamaError.modelNotFound(model) }
        guard (200...299).contains(http.statusCode) else {
            throw OllamaError.badStatus(code: http.statusCode,
                                        message: String(data: data, encoding: .utf8) ?? "ошибка")
        }
    }

    /// Чат без стрима: POST /api/chat (stream:false).
    func chat(messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
        let body = Self.chatBody(messages: messages, settings: settings, stream: false)
        return try OllamaParsing.parseChatResponse(await post("/api/chat", body: body))
    }

    /// Чат со стримом: NDJSON-строки с дельтами текста.
    func chatStream(messages: [ChatMessageDTO],
                    settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: baseURL + "/api/chat") else {
                        throw OllamaError.badURL
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: Self.chatBody(messages: messages,
                                                      settings: settings, stream: true))
                    request.timeoutInterval = 300
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        throw OllamaError.badStatus(
                            code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                            message: "ошибка сервера")
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let parsed = OllamaParsing.parseChatStreamLine(line) else { continue }
                        if !parsed.delta.isEmpty { continuation.yield(.text(parsed.delta)) }
                        if parsed.done {
                            if let usage = parsed.usage { continuation.yield(.usage(usage)) }
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Эмбеддинги: POST /api/embed.
    func embed(texts: [String], model: String) async throws -> [[Float]] {
        let body: [String: Any] = ["model": model, "input": texts]
        return try OllamaParsing.parseEmbedResponse(await post("/api/embed", body: body))
    }

    // MARK: - Внутренности

    /// Тело /api/chat. JSONSerialization вместо Encodable: options — гетерогенный
    /// словарь, а стоп-последовательности опциональны.
    private static func chatBody(messages: [ChatMessageDTO],
                                 settings: ChatSettings,
                                 stream: Bool) -> [String: Any] {
        var options: [String: Any] = [
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "num_predict": settings.maxTokens
        ]
        if !settings.stop.isEmpty { options["stop"] = settings.stop }
        return [
            "model": settings.model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": stream,
            "options": options
        ]
    }

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw OllamaError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OllamaError.badStatus(code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                                        message: "запрос \(path) не удался")
        }
        return data
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw OllamaError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300 // локальная модель может думать долго
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "ошибка"
            throw OllamaError.badStatus(code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                                        message: message)
        }
        return data
    }
}
