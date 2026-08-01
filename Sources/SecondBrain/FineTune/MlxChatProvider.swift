// MlxChatProvider.swift — ChatProvider поверх `mlx_lm.server` (OpenAI-совместимый,
// без ключа). DTO запроса/ответа — из Cloud/OpenAIProvider.swift (не копируем).

import Foundation

struct MlxChatProvider: ChatProvider {
    let port: Int
    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    /// Перед каждым запросом — ensureRunning инжектируется вызывающим (TuningChatViewModel);
    /// после — markUsed, сдвигает idle-окно MlxServerManager. Дефолт — no-op (мок-транспорт в тестах).
    private let beforeSend: () async throws -> Void
    private let afterSend: () -> Void

    init(port: Int,
         transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         beforeSend: @escaping () async throws -> Void = {},
         afterSend: @escaping () -> Void = {}) {
        self.port = port
        self.transport = transport
        self.beforeSend = beforeSend
        self.afterSend = afterSend
    }

    func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
        try await beforeSend()
        defer { afterSend() }
        let request = try makeRequest(messages: messages, settings: settings)
        let (data, response) = try await transport(request)
        try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        let usage = decoded.usage.map {
            ChatUsage(promptTokens: $0.prompt_tokens, completionTokens: $0.completion_tokens, totalTokens: $0.total_tokens)
        }
        return ChatResult(text: text, usage: usage)
    }

    /// Без стриминга (redundancy — обычные `send`): один текстовый чанк, затем usage.
    func stream(_ messages: [ChatMessageDTO], settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await send(messages, settings: settings)
                    continuation.yield(.text(result.text))
                    if let usage = result.usage { continuation.yield(.usage(usage)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(messages: [ChatMessageDTO], settings: ChatSettings) throws -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            throw LLMError.badStatus(code: -1, message: "некорректный адрес mlx-сервера")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequestBody(
            model: settings.model,
            messages: messages.map(RequestMessage.init),
            temperature: settings.temperature,
            top_p: settings.topP,
            max_tokens: settings.maxTokens,
            stop: settings.stop.isEmpty ? nil : settings.stop,
            stream: false
        ))
        request.timeoutInterval = 300
        return request
    }

    /// mlx_lm.server (FastAPI) отдаёт ошибки как `{"detail": "..."}`; формат OpenAI
    /// `{"error": {"message": ...}}` тоже пробуем — оба безопасно фоллбэчат на сырой текст.
    static func errorMessage(from data: Data) -> String? {
        if let detail = try? JSONDecoder().decode(MlxErrorResponse.self, from: data) {
            return detail.detail
        }
        return (try? JSONDecoder().decode(OpenAIStyleErrorResponse.self, from: data))?.error.message
    }
}

private struct MlxErrorResponse: Decodable {
    let detail: String
}

private struct OpenAIStyleErrorResponse: Decodable {
    let error: APIError
    struct APIError: Decodable { let message: String }
}
