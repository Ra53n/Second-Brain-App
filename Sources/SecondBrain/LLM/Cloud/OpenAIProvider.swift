// OpenAIProvider.swift — OpenAI: чат (+SSE-стриминг), Whisper-транскрипция,
// эмбеддинги.
//
// baseURL настраиваемый: тот же клиент бесплатно обслуживает любой
// OpenAI-совместимый эндпоинт (DeepSeek, OpenRouter, локальные раннеры) —
// задел на будущее, но в этой задаче регистрируется только официальный OpenAI.
//
// Транскрипция длинного аудио: у Whisper лимит 25 МБ на файл. Если файл
// больше — режем по длительности (AudioChunker), транскрибируем части, склеиваем
// текст и сегменты со сдвигом таймкодов, между частями — маркер границы.
//
// Эталон обработки не-2xx — DeepSeekClient.swift (Manager Assistant); формат
// ошибки OpenAI подтверждён живым запросом без ключа:
//   {"error": {"message": "...", "type": "...", "param": null, "code": null}}

import Foundation

struct OpenAIProvider: ChatProvider, TranscriptionProvider, EmbeddingProvider {
    static let id: ProviderID = "openai"

    let baseURL: URL
    /// Под каким id искать ключ в KeyStore и подписывать ошибки (задача 26):
    /// тот же клиент обслуживает OpenRouter/DeepSeek со своими ключами.
    let keyID: ProviderID
    /// Модель транскрипции «зашита» в экземпляр (протокол TranscriptionProvider
    /// не принимает модель параметром — см. LLM/ProviderProtocols.swift).
    let transcriptionModel: String
    let dimension: Int
    /// Whisper API отказывает файлам больше этого размера — режем заранее.
    let maxAudioBytes: Int

    init(
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        keyID: ProviderID = OpenAIProvider.id,
        transcriptionModel: String = "whisper-1",
        dimension: Int = 1536, // text-embedding-3-small
        maxAudioBytes: Int = 25 * 1024 * 1024
    ) {
        self.baseURL = baseURL
        self.keyID = keyID
        self.transcriptionModel = transcriptionModel
        self.dimension = dimension
        self.maxAudioBytes = maxAudioBytes
    }

    // MARK: - ChatProvider

    func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
        let key = try apiKey()
        let body = ChatRequestBody(
            model: settings.model,
            messages: messages.map(RequestMessage.init),
            temperature: settings.temperature,
            top_p: settings.topP,
            max_tokens: settings.maxTokens,
            stop: settings.stop.isEmpty ? nil : settings.stop,
            stream: false
        )
        let data = try await post(path: "chat/completions", body: body, apiKey: key)
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        let usage = decoded.usage.map {
            ChatUsage(promptTokens: $0.prompt_tokens, completionTokens: $0.completion_tokens, totalTokens: $0.total_tokens)
        }
        return ChatResult(text: text, usage: usage)
    }

    func stream(_ messages: [ChatMessageDTO], settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = try apiKey()
                    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONEncoder().encode(ChatRequestBody(
                        model: settings.model,
                        messages: messages.map(RequestMessage.init),
                        temperature: settings.temperature,
                        top_p: settings.topP,
                        max_tokens: settings.maxTokens,
                        stop: settings.stop.isEmpty ? nil : settings.stop,
                        stream: true,
                        // Задача 29: usage приходит финальным чанком стрима.
                        stream_options: ChatRequestBody.StreamOptions(include_usage: true)
                    ))
                    request.timeoutInterval = 300

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        let data = try await CloudHTTP.drain(bytes)
                        try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)
                    }

                    for try await payload in SSEStream.payloads(from: bytes.lines) {
                        guard let chunkData = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: chunkData)
                        else { continue }
                        // ВАЖНО: usage-чанк приходит с choices: [] — разбираем
                        // usage ДО guard'а на дельту текста.
                        if let usage = chunk.usage {
                            continuation.yield(.usage(ChatUsage(
                                promptTokens: usage.prompt_tokens,
                                completionTokens: usage.completion_tokens,
                                totalTokens: usage.total_tokens)))
                        }
                        if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                            continuation.yield(.text(delta))
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
        let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? nil
        guard let size, size > maxAudioBytes else {
            return try await transcribeSingleFile(audioURL, language: language, hints: hints)
        }

        // Длинная запись — режем по длительности, транскрибируем части, склеиваем.
        let asset = AVURLAssetDuration(audioURL)
        let duration = try await asset.load()
        // Пропорция «лимит байт → лимит секунд» по фактическому битрейту файла;
        // 5% запас на контейнер/накладные расходы формата после экспорта в m4a.
        let bytesPerSecond = Double(size) / max(duration, 1)
        let maxChunkDuration = (Double(maxAudioBytes) / bytesPerSecond) * 0.95
        let plan = AudioChunker.planChunks(duration: duration, maxChunkDuration: maxChunkDuration)
        guard plan.count > 1 else {
            return try await transcribeSingleFile(audioURL, language: language, hints: hints)
        }

        let chunkURLs = try await AudioChunker.exportChunks(of: audioURL, plan: plan)
        defer { chunkURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        var fullText: [String] = []
        var segments: [TranscriptSegment] = []
        for (index, (chunkURL, chunkPlan)) in zip(chunkURLs, plan).enumerated() {
            let transcript = try await transcribeSingleFile(chunkURL, language: language, hints: hints)
            fullText.append("[Часть \(index + 1)] \(transcript.fullText)")
            segments.append(contentsOf: transcript.segments.map {
                TranscriptSegment(
                    text: $0.text,
                    start: $0.start.map { $0 + chunkPlan.start },
                    end: $0.end.map { $0 + chunkPlan.start }
                )
            })
        }
        return Transcript(fullText: fullText.joined(separator: "\n\n"), segments: segments, language: language)
    }

    private func transcribeSingleFile(_ audioURL: URL, language: String?, hints: String?) async throws -> Transcript {
        let key = try apiKey()
        let audioData = try Data(contentsOf: audioURL)

        var form = MultipartFormData()
        form.addField(name: "model", value: transcriptionModel)
        // gpt-4o-transcribe не поддерживает verbose_json (нет сегментов с таймкодами);
        // whisper-1 — поддерживает, берём таймкоды именно у него.
        if transcriptionModel == "whisper-1" {
            form.addField(name: "response_format", value: "verbose_json")
        }
        if let language { form.addField(name: "language", value: language) }
        if let hints { form.addField(name: "prompt", value: hints) }
        form.addFile(name: "file", filename: audioURL.lastPathComponent,
                     mimeType: Self.mimeType(for: audioURL), data: audioData)
        let body = form.finalize()

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)

        if transcriptionModel == "whisper-1" {
            let decoded = try JSONDecoder().decode(WhisperVerboseResponse.self, from: data)
            let segments = decoded.segments?.map {
                TranscriptSegment(text: $0.text.trimmingCharacters(in: .whitespaces), start: $0.start, end: $0.end)
            } ?? []
            return Transcript(fullText: decoded.text, segments: segments, language: decoded.language ?? language)
        } else {
            let decoded = try JSONDecoder().decode(SimpleTranscriptionResponse.self, from: data)
            return Transcript(fullText: decoded.text, segments: [], language: language)
        }
    }

    /// MIME по расширению файла (как у Deepgram/Gemini). Раньше был захардкожен
    /// audio/mpeg — для наших записей .m4a это несоответствие контейнера и
    /// заявленного типа, отдельные бэкенды на нём спотыкаются.
    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        default: return "audio/mpeg"
        }
    }

    // MARK: - EmbeddingProvider

    /// Модель эмбеддинга по умолчанию (роутер может переопределить, задача 28).
    static let defaultEmbeddingModel = "text-embedding-3-small"

    func embed(_ texts: [String], model: String?) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let key = try apiKey()
        let body = EmbeddingRequestBody(model: model ?? Self.defaultEmbeddingModel, input: texts)
        let data = try await post(path: "embeddings", body: body, apiKey: key)
        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        return decoded.data
            .sorted { $0.index < $1.index }
            .map { $0.embedding }
    }

    // MARK: - Внутреннее

    func apiKey() throws -> String {
        guard let key = KeyStore.key(for: keyID) else { throw LLMError.missingAPIKey(keyID) }
        return key
    }

    func post<Body: Encodable>(path: String, body: Body, apiKey: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)
        return data
    }

    /// Формат ошибки OpenAI: {"error": {"message": ..., "type": ..., ...}}.
    static func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data))?.error.message
    }
}

// MARK: - DTO запроса чата

struct ChatRequestBody: Encodable {
    /// stream_options.include_usage=true → финальный SSE-чанк несёт usage
    /// (задача 29). nil — ключ не сериализуется (обычные запросы).
    struct StreamOptions: Encodable {
        let include_usage: Bool
    }

    let model: String
    let messages: [RequestMessage]
    let temperature: Double
    let top_p: Double
    let max_tokens: Int
    let stop: [String]?
    let stream: Bool
    var stream_options: StreamOptions? = nil
}

struct RequestMessage: Encodable {
    let role: String
    let content: String
    init(_ message: ChatMessageDTO) {
        role = message.role.rawValue
        content = message.content
    }
}

// MARK: - DTO ответа чата

struct ChatCompletionResponse: Decodable {
    let choices: [Choice]
    let usage: Usage?
    struct Choice: Decodable { let message: Message }
    struct Message: Decodable { let content: String? }
    struct Usage: Decodable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
}

struct ChatCompletionChunk: Decodable {
    let choices: [Choice]
    /// Финальный чанк при include_usage (choices пустой).
    let usage: ChatCompletionResponse.Usage?
    struct Choice: Decodable { let delta: Delta }
    struct Delta: Decodable { let content: String? }
}

// MARK: - DTO транскрипции

struct WhisperVerboseResponse: Decodable {
    let text: String
    let language: String?
    let segments: [Segment]?
    struct Segment: Decodable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }
}

struct SimpleTranscriptionResponse: Decodable {
    let text: String
}

// MARK: - DTO эмбеддингов

struct EmbeddingRequestBody: Encodable {
    let model: String
    let input: [String]
}

struct EmbeddingResponse: Decodable {
    let data: [Item]
    struct Item: Decodable {
        let index: Int
        let embedding: [Float]
    }
}

// MARK: - DTO ошибки

private struct OpenAIErrorResponse: Decodable {
    let error: APIError
    struct APIError: Decodable {
        let message: String
        let type: String?
    }
}

// MARK: - Длительность аудио (обёртка над AVFoundation для тестируемости выше)

import AVFoundation

private struct AVURLAssetDuration {
    let url: URL
    init(_ url: URL) { self.url = url }
    func load() async throws -> TimeInterval {
        try await CMTimeGetSeconds(AVURLAsset(url: url).load(.duration))
    }
}
