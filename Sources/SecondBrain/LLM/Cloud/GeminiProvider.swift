// GeminiProvider.swift — Google Gemini: чат (+SSE-стриминг), транскрипция аудио
// (inline для <20 МБ, Files API для больших файлов), эмбеддинги.
//
// Особенности API Gemini относительно OpenAI-совместимых:
//  - ключ передаётся query-параметром `?key=`, не заголовком Authorization;
//  - роли — «user»/«model» (не «assistant»); системный промпт — отдельное
//    поле systemInstruction, а не сообщение с ролью;
//  - транскрипция — не отдельный эндпоинт, а обычный generateContent с аудио
//    как частью контента (inlineData — база64 до 20 МБ; больше — Files API:
//    загрузить файл, дождаться ACTIVE, сослаться fileData.fileUri);
//  - таймкоды по словам Gemini не отдаёт — Transcript.segments всегда пуст.
//
// Формат ошибки подтверждён живым запросом без ключа:
//   {"error": {"code": 403, "message": "...", "status": "PERMISSION_DENIED"}}

import Foundation

struct GeminiProvider: ChatProvider, TranscriptionProvider, EmbeddingProvider {
    static let id: ProviderID = "gemini"

    let baseURL: URL
    let embeddingModel: String
    let dimension: Int
    /// Порог, после которого аудио грузится через Files API вместо inline base64
    /// (документированный лимит Gemini на inline-данные — 20 МБ).
    let inlineAudioLimitBytes: Int

    init(
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        embeddingModel: String = "text-embedding-004",
        dimension: Int = 768,
        inlineAudioLimitBytes: Int = 20 * 1024 * 1024
    ) {
        self.baseURL = baseURL
        self.embeddingModel = embeddingModel
        self.dimension = dimension
        self.inlineAudioLimitBytes = inlineAudioLimitBytes
    }

    // MARK: - ChatProvider

    func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
        let key = try apiKey()
        let body = makeGenerateContentBody(messages, settings: settings)
        let url = baseURL
            .appendingPathComponent("models/\(settings.model):generateContent")
            .appending(queryItems: [URLQueryItem(name: "key", value: key)])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)

        let decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        let usage = decoded.usageMetadata.map {
            ChatUsage(
                promptTokens: $0.promptTokenCount,
                completionTokens: $0.candidatesTokenCount ?? 0,
                totalTokens: $0.totalTokenCount
            )
        }
        return ChatResult(text: text, usage: usage)
    }

    func stream(_ messages: [ChatMessageDTO], settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = try apiKey()
                    let body = makeGenerateContentBody(messages, settings: settings)
                    let url = baseURL
                        .appendingPathComponent("models/\(settings.model):streamGenerateContent")
                        .appending(queryItems: [
                            URLQueryItem(name: "alt", value: "sse"),
                            URLQueryItem(name: "key", value: key)
                        ])

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(body)
                    request.timeoutInterval = 300

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        let data = try await CloudHTTP.drain(bytes)
                        try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)
                    }

                    for try await payload in SSEStream.payloads(from: bytes.lines) {
                        guard let chunkData = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(GenerateContentResponse.self, from: chunkData)
                        else { continue }
                        // usage растёт по чанкам — последнее событие выигрывает
                        // (задача 29, consumer хранит последний usage).
                        if let meta = chunk.usageMetadata {
                            continuation.yield(.usage(ChatUsage(
                                promptTokens: meta.promptTokenCount,
                                completionTokens: meta.candidatesTokenCount ?? 0,
                                totalTokens: meta.totalTokenCount)))
                        }
                        if let text = chunk.candidates?.first?.content?.parts?.first?.text,
                           !text.isEmpty {
                            continuation.yield(.text(text))
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

    // MARK: - TranscriptionProvider

    func transcribe(audioURL: URL, language: String?, hints: String?) async throws -> Transcript {
        let key = try apiKey()
        let data = try Data(contentsOf: audioURL)
        let mimeType = Self.mimeType(for: audioURL)
        let instruction = "Транскрибируй аудио дословно, без пересказа и комментариев."
            + (hints.map { " Контекст/термины: \($0)." } ?? "")

        let audioPart: GeneratePart
        if data.count <= inlineAudioLimitBytes {
            audioPart = .inline(mimeType: mimeType, base64: data.base64EncodedString())
        } else {
            let uploaded = try await uploadFile(data: data, mimeType: mimeType, displayName: audioURL.lastPathComponent, apiKey: key)
            let active = try await waitUntilActive(uploaded, apiKey: key)
            audioPart = .file(uri: active.uri, mimeType: mimeType)
        }

        let body = GenerateContentRequest(
            contents: [Content(role: "user", parts: [.text(instruction), audioPart])],
            systemInstruction: nil
        )
        let url = baseURL
            .appendingPathComponent("models/gemini-2.0-flash:generateContent")
            .appending(queryItems: [URLQueryItem(name: "key", value: key)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 300

        let (responseData, response) = try await URLSession.shared.data(for: request)
        try CloudHTTP.ensureSuccess(response, data: responseData, mapError: Self.errorMessage)

        let decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: responseData)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        // Gemini не отдаёт таймкоды по словам — сегментов нет (в отличие от Deepgram).
        return Transcript(fullText: text, segments: [], language: language)
    }

    // MARK: - Files API (аудио > inlineAudioLimitBytes)

    private func uploadFile(data: Data, mimeType: String, displayName: String, apiKey: String) async throws -> GeminiFile {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8Data)
        body.append((try JSONEncoder().encode(FileMetadata(file: .init(displayName: displayName)))))
        body.append("\r\n--\(boundary)\r\n".utf8Data)
        body.append("Content-Type: \(mimeType)\r\n\r\n".utf8Data)
        body.append(data)
        body.append("\r\n--\(boundary)--".utf8Data)

        let uploadBaseURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!
        var request = URLRequest(url: uploadBaseURL.appending(queryItems: [URLQueryItem(name: "key", value: apiKey)]))
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("multipart", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.httpBody = body
        request.timeoutInterval = 300

        let (responseData, response) = try await URLSession.shared.data(for: request)
        try CloudHTTP.ensureSuccess(response, data: responseData, mapError: Self.errorMessage)
        return try JSONDecoder().decode(FileUploadResponse.self, from: responseData).file
    }

    /// Ждёт, пока загруженный файл перейдёт из PROCESSING в ACTIVE (аудио/видео
    /// обрабатывается асинхронно на стороне Google). Лимит попыток — защита от
    /// вечного ожидания, если файл застрял в FAILED/PROCESSING.
    private func waitUntilActive(_ file: GeminiFile, apiKey: String, maxAttempts: Int = 30) async throws -> GeminiFile {
        var current = file
        var attempt = 0
        while current.state == "PROCESSING", attempt < maxAttempts {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(current.name)")!
                .appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)
            current = try JSONDecoder().decode(GeminiFile.self, from: data)
            attempt += 1
        }
        guard current.state == "ACTIVE" else {
            throw LLMError.badStatus(code: -1, message: "файл «\(file.displayName ?? file.name)» не обработан Gemini (состояние: \(current.state))")
        }
        return current
    }

    // MARK: - EmbeddingProvider

    func embed(_ texts: [String], model: String?) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let key = try apiKey()
        let effectiveModel = model ?? embeddingModel
        let body = BatchEmbedRequest(requests: texts.map {
            BatchEmbedRequest.Request(model: "models/\(effectiveModel)", content: Content(role: nil, parts: [.text($0)]))
        })
        let url = baseURL
            .appendingPathComponent("models/\(effectiveModel):batchEmbedContents")
            .appending(queryItems: [URLQueryItem(name: "key", value: key)])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)
        return try JSONDecoder().decode(BatchEmbedResponse.self, from: data).embeddings.map(\.values)
    }

    // MARK: - Внутреннее

    private func apiKey() throws -> String {
        guard let key = KeyStore.key(for: Self.id) else { throw LLMError.missingAPIKey(Self.id) }
        return key
    }

    /// Собирает contents/systemInstruction из ChatMessageDTO: system-сообщения
    /// объединяются в systemInstruction (Gemini не принимает роль «system» в contents).
    /// Не private: маппинг ролей (system→systemInstruction, assistant→model)
    /// проверяется тестами без сети.
    func makeGenerateContentBody(_ messages: [ChatMessageDTO], settings: ChatSettings) -> GenerateContentRequest {
        let systemText = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n")
        let contents = messages
            .filter { $0.role != .system }
            .map { Content(role: $0.role == .assistant ? "model" : "user", parts: [.text($0.content)]) }
        return GenerateContentRequest(
            contents: contents,
            systemInstruction: systemText.isEmpty ? nil : Content(role: nil, parts: [.text(systemText)])
        )
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        default: return "audio/mpeg"
        }
    }

    /// Формат ошибки Gemini: {"error": {"code": ..., "message": ..., "status": ...}}.
    static func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(GeminiErrorResponse.self, from: data))?.error.message
    }
}

// MARK: - DTO запроса/ответа чата

struct GenerateContentRequest: Encodable {
    let contents: [Content]
    let systemInstruction: Content?
}

struct Content: Codable {
    let role: String?
    let parts: [GeneratePart]?
    init(role: String?, parts: [GeneratePart]) {
        self.role = role
        self.parts = parts
    }
}

/// Часть контента: текст, inline-аудио (base64) или ссылка на загруженный файл.
enum GeneratePart: Codable {
    case text(String)
    case inline(mimeType: String, base64: String)
    case file(uri: String, mimeType: String)

    private enum CodingKeys: String, CodingKey {
        case text, inlineData, fileData
    }
    private enum InlineKeys: String, CodingKey {
        case mimeType, data
    }
    private enum FileKeys: String, CodingKey {
        case fileUri, mimeType
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(value, forKey: .text)
        case .inline(let mimeType, let base64):
            var nested = container.nestedContainer(keyedBy: InlineKeys.self, forKey: .inlineData)
            try nested.encode(mimeType, forKey: .mimeType)
            try nested.encode(base64, forKey: .data)
        case .file(let uri, let mimeType):
            var nested = container.nestedContainer(keyedBy: FileKeys.self, forKey: .fileData)
            try nested.encode(uri, forKey: .fileUri)
            try nested.encode(mimeType, forKey: .mimeType)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else {
            self = .text("") // ответы модели содержат только text-части в нашем использовании
        }
    }

    /// Текст части, если это текстовая часть (для чтения ответа модели).
    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

struct GenerateContentResponse: Decodable {
    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?
    struct Candidate: Decodable {
        let content: ResponseContent?
    }
    struct ResponseContent: Decodable {
        let parts: [GeneratePart]?
    }
    struct UsageMetadata: Decodable {
        let promptTokenCount: Int
        let candidatesTokenCount: Int?
        let totalTokenCount: Int
    }
}

// MARK: - Files API DTO

private struct FileMetadata: Encodable {
    struct File: Encodable { let displayName: String }
    let file: File
}

private struct FileUploadResponse: Decodable {
    let file: GeminiFile
}

private struct GeminiFile: Decodable {
    let name: String
    let uri: String
    let state: String
    let displayName: String?
}

// MARK: - Эмбеддинги DTO

struct BatchEmbedRequest: Encodable {
    let requests: [Request]
    struct Request: Encodable {
        let model: String
        let content: Content
    }
}

struct BatchEmbedResponse: Decodable {
    let embeddings: [Embedding]
    struct Embedding: Decodable { let values: [Float] }
}

// MARK: - Ошибка

private struct GeminiErrorResponse: Decodable {
    let error: APIError
    struct APIError: Decodable {
        let code: Int
        let message: String
        let status: String?
    }
}
