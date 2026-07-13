// ToolUse.swift — tool-use цикл поверх ChatProvider'ов (задача 15).
//
// Наш протокол ChatProvider (07) не знает про инструменты — расширение
// ToolCapableChatProvider добавляет sendWithTools; его реализуют OpenAI
// (OpenAI function calling) и Ollama (native tools того же формата).
// Gemini: конверсия схемы в functionDeclarations реализована и
// протестирована, но sendWithTools для Gemini не подключён (другой формат
// диалога parts/functionCall — бэклог; чат честно скажет, что провайдер не
// умеет инструменты).
//
// Цикл (порт runToolLoop из MA): запрос с tools → модель вернула tool_calls →
// исполняем через execute-замыкание (MCPManager.call, ошибки текстом ERROR) →
// добавляем assistant+tool сообщения → повтор до maxIterations; на последней
// итерации форсируем текст (forceText → tool_choice="none").

import Foundation

// MARK: - DTO

/// Описание инструмента, независимое от провайдера.
struct ToolDefinition: Equatable, Sendable {
    var name: String
    var description: String
    var schema: JSONValue // JSON Schema аргументов

    init(name: String, description: String, schema: JSONValue) {
        self.name = name
        self.description = description
        self.schema = schema
    }

    init(spec: ToolSpec) {
        self.init(name: spec.qualifiedName, description: spec.description, schema: spec.schema)
    }
}

/// Запрошенный моделью вызов инструмента.
struct ToolCallRequest: Equatable, Sendable {
    var id: String
    var name: String
    var argumentsJSON: String // JSON-строка аргументов, как отдала модель
}

/// Сообщение диалога с поддержкой инструментов (надмножество ChatMessageDTO).
struct ToolAwareMessage: Equatable, Sendable {
    enum Role: String { case system, user, assistant, tool }
    var role: Role
    var content: String?
    var toolCalls: [ToolCallRequest] = []
    var toolCallID: String? // для role=tool: на какой вызов отвечаем

    init(role: Role, content: String?, toolCalls: [ToolCallRequest] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    init(_ dto: ChatMessageDTO) {
        self.init(role: Role(rawValue: dto.role.rawValue) ?? .user, content: dto.content)
    }
}

/// Один шаг цикла: либо текст, либо запрошенные вызовы (либо и то и то).
struct ToolLoopStep: Equatable {
    var text: String?
    var toolCalls: [ToolCallRequest]
    var usage: ChatUsage?
}

/// Провайдер, умеющий function calling.
protocol ToolCapableChatProvider {
    /// forceText — запретить инструменты в этом запросе (tool_choice="none").
    func sendWithTools(_ messages: [ToolAwareMessage],
                       settings: ChatSettings,
                       tools: [ToolDefinition],
                       forceText: Bool) async throws -> ToolLoopStep
}

/// Запись вызова для показа в чате и персистентности (свёрнутый блок).
struct ToolCallDisplay: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var argumentsJSON: String
    var result: String
    var ok: Bool

    enum CodingKeys: String, CodingKey { case id, name, argumentsJSON, result, ok }

    init(name: String, argumentsJSON: String, result: String, ok: Bool) {
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.result = result
        self.ok = ok
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        argumentsJSON = try c.decodeIfPresent(String.self, forKey: .argumentsJSON) ?? ""
        result = try c.decodeIfPresent(String.self, forKey: .result) ?? ""
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
    }
}

// MARK: - Конверсия схем

enum ToolSchemaConversion {
    /// MCP-схема → OpenAI function-calling (тот же формат ест Ollama).
    /// Не-объект вместо схемы → пустой объект-схема (требование OpenAI).
    static func openAITool(_ tool: ToolDefinition) -> JSONValue {
        let schema: JSONValue = tool.schema.objectValue != nil
            ? tool.schema
            : .object(["type": .string("object"), "properties": .object([:])])
        var function: [String: JSONValue] = [
            "name": .string(tool.name),
            "parameters": schema
        ]
        if !tool.description.isEmpty {
            function["description"] = .string(tool.description)
        }
        return .object(["type": .string("function"), "function": .object(function)])
    }

    /// Поля JSON Schema, которые понимает Gemini functionDeclarations
    /// (OpenAPI-подмножество); остальное ($schema, additionalProperties…)
    /// вырезается рекурсивно — иначе API отвечает 400.
    private static let geminiAllowedKeys: Set<String> = [
        "type", "format", "description", "nullable", "enum",
        "properties", "required", "items"
    ]

    /// MCP-схема → Gemini functionDeclaration.
    static func geminiFunctionDeclaration(_ tool: ToolDefinition) -> JSONValue {
        let cleaned = cleanForGemini(tool.schema)
        let parameters: JSONValue = cleaned.objectValue != nil
            ? cleaned
            : .object(["type": .string("object"), "properties": .object([:])])
        return .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": parameters
        ])
    }

    /// Рекурсивная чистка схемы под Gemini.
    static func cleanForGemini(_ value: JSONValue) -> JSONValue {
        guard let object = value.objectValue else { return value }
        var result: [String: JSONValue] = [:]
        for (key, inner) in object where geminiAllowedKeys.contains(key) {
            switch key {
            case "properties":
                guard let props = inner.objectValue else { continue }
                var cleanedProps: [String: JSONValue] = [:]
                for (name, schema) in props { cleanedProps[name] = cleanForGemini(schema) }
                result[key] = .object(cleanedProps)
            case "items":
                result[key] = cleanForGemini(inner)
            default:
                result[key] = inner
            }
        }
        return .object(result)
    }
}

// MARK: - Цикл

enum ToolUseLoop {
    /// Итог цикла: финальный текст + транскрипт вызовов + суммарные токены.
    struct Outcome: Equatable {
        var text: String
        var transcript: [ToolCallDisplay]
        var usage: ChatUsage?
    }

    static let defaultMaxIterations = 6

    /// Ядро агентного цикла (порт runToolLoop MA).
    static func run(provider: ToolCapableChatProvider,
                    settings: ChatSettings,
                    messages initial: [ToolAwareMessage],
                    tools: [ToolDefinition],
                    maxIterations: Int = defaultMaxIterations,
                    execute: (String, String) async -> String) async throws -> Outcome {
        var messages = initial
        var transcript: [ToolCallDisplay] = []
        var promptTokens = 0, completionTokens = 0, totalTokens = 0
        var sawUsage = false

        for iteration in 0..<max(1, maxIterations) {
            let isLast = iteration == max(1, maxIterations) - 1
            let step = try await provider.sendWithTools(messages,
                                                        settings: settings,
                                                        tools: tools,
                                                        forceText: isLast)
            if let usage = step.usage {
                sawUsage = true
                promptTokens += usage.promptTokens
                completionTokens += usage.completionTokens
                totalTokens += usage.totalTokens
            }

            if step.toolCalls.isEmpty || isLast {
                let text = step.text ?? ""
                guard !text.isEmpty else { throw LLMError.emptyResponse }
                let usage = sawUsage
                    ? ChatUsage(promptTokens: promptTokens,
                                completionTokens: completionTokens,
                                totalTokens: totalTokens)
                    : nil
                return Outcome(text: text, transcript: transcript, usage: usage)
            }

            // Модель просит инструменты: фиксируем её сообщение, исполняем, отвечаем.
            messages.append(ToolAwareMessage(role: .assistant,
                                             content: step.text,
                                             toolCalls: step.toolCalls))
            for call in step.toolCalls {
                let output = await execute(call.name, call.argumentsJSON)
                transcript.append(ToolCallDisplay(name: call.name,
                                                  argumentsJSON: call.argumentsJSON,
                                                  result: output,
                                                  ok: !output.hasPrefix("ERROR")))
                messages.append(ToolAwareMessage(role: .tool,
                                                 content: output,
                                                 toolCallID: call.id))
            }
        }
        throw LLMError.emptyResponse // недостижимо: isLast обработан выше
    }
}
