// ProviderToolSupport.swift — sendWithTools для конкретных провайдеров.
//
// OpenAI: штатный function calling (tools/tool_choice в chat/completions,
// tool_calls в ответе, arguments — JSON-строка).
// Ollama: native tools в /api/chat — тот же OpenAI-формат описаний, но
// arguments в ответе — ОБЪЕКТ (не строка), id вызова отсутствует
// (синтезируем); tool_choice не поддержан — forceText просто не шлёт tools.
// Gemini: не подключён (другой формат диалога parts/functionCall) —
// зафиксировано в «Результате» задачи 15; конверсия схемы готова и
// протестирована (ToolSchemaConversion.geminiFunctionDeclaration).

import Foundation

// MARK: - OpenAI

/// DTO tools-пути OpenAI (отдельные от обычного ChatRequestBody —
/// не трогаем стабильный код задачи 08).
struct OpenAIToolRequestBody: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let max_tokens: Int
    let stream = false
    let tools: [JSONValue]?
    let tool_choice: String?

    struct Message: Encodable {
        let role: String
        let content: String?
        let tool_calls: [ToolCallDTO]?
        let tool_call_id: String?

        init(_ message: ToolAwareMessage) {
            role = message.role.rawValue
            content = message.content
            tool_calls = message.toolCalls.isEmpty ? nil : message.toolCalls.map(ToolCallDTO.init)
            tool_call_id = message.toolCallID
        }
    }
}

/// Вызов инструмента в OpenAI-формате (запрос и ответ).
struct ToolCallDTO: Codable {
    let id: String
    let type: String
    let function: Function

    struct Function: Codable {
        let name: String
        let arguments: String // JSON-строка, как отдаёт модель
    }

    init(_ call: ToolCallRequest) {
        id = call.id
        type = "function"
        function = Function(name: call.name, arguments: call.argumentsJSON)
    }
}

struct OpenAIToolResponse: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable { let message: Message }
    struct Message: Decodable {
        let content: String?
        let tool_calls: [ToolCallDTO]?
    }
    struct Usage: Decodable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
}

extension OpenAIProvider: ToolCapableChatProvider {
    func sendWithTools(_ messages: [ToolAwareMessage],
                       settings: ChatSettings,
                       tools: [ToolDefinition],
                       forceText: Bool) async throws -> ToolLoopStep {
        let key = try apiKey()
        let body = OpenAIToolRequestBody(
            model: settings.model,
            messages: messages.map(OpenAIToolRequestBody.Message.init),
            temperature: settings.temperature,
            max_tokens: settings.maxTokens,
            tools: tools.isEmpty ? nil : tools.map(ToolSchemaConversion.openAITool),
            tool_choice: tools.isEmpty ? nil : (forceText ? "none" : "auto"))
        let data = try await post(path: "chat/completions", body: body, apiKey: key)
        let decoded = try JSONDecoder().decode(OpenAIToolResponse.self, from: data)
        guard let message = decoded.choices.first?.message else { throw LLMError.emptyResponse }
        let calls = (message.tool_calls ?? []).map {
            ToolCallRequest(id: $0.id, name: $0.function.name, argumentsJSON: $0.function.arguments)
        }
        let usage = decoded.usage.map {
            ChatUsage(promptTokens: $0.prompt_tokens,
                      completionTokens: $0.completion_tokens,
                      totalTokens: $0.total_tokens)
        }
        return ToolLoopStep(text: message.content, toolCalls: calls, usage: usage)
    }
}

// MARK: - Ollama

extension OllamaClient {
    /// /api/chat с tools (native у Ollama, формат описаний — OpenAI).
    func chatWithTools(messages: [ToolAwareMessage],
                       settings: ChatSettings,
                       tools: [ToolDefinition],
                       forceText: Bool) async throws -> ToolLoopStep {
        var body: [String: JSONValue] = [
            "model": .string(settings.model),
            "messages": .array(messages.map(Self.toolMessageJSON)),
            "stream": .bool(false),
            "options": .object(["temperature": .double(settings.temperature),
                                "num_predict": .int(settings.maxTokens)])
        ]
        // tool_choice у Ollama нет: «запретить инструменты» = не отправлять их.
        if !tools.isEmpty, !forceText {
            body["tools"] = .array(tools.map(ToolSchemaConversion.openAITool))
        }
        let data = try await postJSONValue("/api/chat", body: .object(body))
        return try OllamaParsing.parseChatToolResponse(data)
    }

    /// ToolAwareMessage → JSON Ollama: assistant.tool_calls.arguments — ОБЪЕКТ.
    static func toolMessageJSON(_ message: ToolAwareMessage) -> JSONValue {
        var object: [String: JSONValue] = [
            "role": .string(message.role.rawValue),
            "content": .string(message.content ?? "")
        ]
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = .array(message.toolCalls.map { call in
                .object(["function": .object([
                    "name": .string(call.name),
                    "arguments": JSONValue.parse(call.argumentsJSON) ?? .object([:])
                ])])
            })
        }
        return .object(object)
    }

    /// POST с JSONValue-телом (гетерогенный JSON без Encodable-обвязки).
    func postJSONValue(_ path: String, body: JSONValue) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw OllamaError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "ошибка"
            throw OllamaError.badStatus(code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                                        message: message)
        }
        return data
    }
}

extension OllamaParsing {
    /// Ответ /api/chat с tool_calls: arguments-объект → JSON-строка,
    /// id вызова синтезируется (Ollama его не отдаёт).
    static func parseChatToolResponse(_ data: Data) throws -> ToolLoopStep {
        struct Response: Decodable {
            struct Message: Decodable {
                struct Call: Decodable {
                    struct Function: Decodable {
                        let name: String
                        let arguments: JSONValue?
                    }
                    let function: Function
                }
                let content: String?
                let tool_calls: [Call]?
            }
            let message: Message?
            let prompt_eval_count: Int?
            let eval_count: Int?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let calls = (decoded.message?.tool_calls ?? []).enumerated().map { index, call in
            ToolCallRequest(id: "call_\(index)",
                            name: call.function.name,
                            argumentsJSON: (call.function.arguments ?? .object([:])).jsonString)
        }
        var usage: ChatUsage?
        if let prompt = decoded.prompt_eval_count, let completion = decoded.eval_count {
            usage = ChatUsage(promptTokens: prompt, completionTokens: completion,
                              totalTokens: prompt + completion)
        }
        return ToolLoopStep(text: decoded.message?.content, toolCalls: calls, usage: usage)
    }
}

extension OllamaProvider: ToolCapableChatProvider {
    func sendWithTools(_ messages: [ToolAwareMessage],
                       settings: ChatSettings,
                       tools: [ToolDefinition],
                       forceText: Bool) async throws -> ToolLoopStep {
        try await manager.ensureRunning()
        let step = try await client.chatWithTools(messages: messages,
                                                  settings: settings,
                                                  tools: tools,
                                                  forceText: forceText)
        await manager.markUsed()
        return step
    }
}
