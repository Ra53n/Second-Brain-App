// MCPTests.swift — задача 15 (порт MCPTests из MA + новые): JSONValue и
// JSON-RPC конверты, конверсия MCP-схем в форматы OpenAI и Gemini, tool-use
// цикл на моках (одно-/двухшаговый, лимит итераций, ошибка сервера → текст
// ERROR), именование инструментов, конфиг (Claude-импорт, keychain-env,
// снисходительные миграции).

import XCTest
@testable import SecondBrain

// MARK: - JSONValue / JSON-RPC

final class MCPProtocolTests: XCTestCase {
    private let dec = JSONDecoder()
    private let enc = JSONEncoder()

    func testJSONValueIntVsDouble() throws {
        // «1» должно остаться int, «1.5» — double (порядок проб в init важен).
        XCTAssertEqual(try dec.decode(JSONValue.self, from: Data("1".utf8)), .int(1))
        XCTAssertEqual(try dec.decode(JSONValue.self, from: Data("1.5".utf8)), .double(1.5))
        XCTAssertEqual(try dec.decode(JSONValue.self, from: Data("true".utf8)), .bool(true))
        XCTAssertEqual(try dec.decode(JSONValue.self, from: Data("null".utf8)), .null)
    }

    func testJSONValueRoundTripSchema() throws {
        let json = #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#
        let value = try dec.decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["type"]?.stringValue, "object")
        XCTAssertEqual(value["properties"]?["title"]?["type"]?.stringValue, "string")
        // Round-trip: перекодируем и декодируем снова — эквивалентно.
        let again = try dec.decode(JSONValue.self, from: enc.encode(value))
        XCTAssertEqual(again, value)
    }

    func testRPCRequestEncodes() throws {
        let request = RPCRequest(id: 7, method: "tools/list", params: nil)
        let object = try JSONSerialization.jsonObject(with: enc.encode(request)) as? [String: Any]
        XCTAssertEqual(object?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object?["id"] as? Int, 7)
        XCTAssertEqual(object?["method"] as? String, "tools/list")
    }

    func testRPCIncomingResultVsErrorVsNotification() throws {
        let ok = try dec.decode(RPCIncoming.self,
            from: Data(#"{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}"#.utf8))
        XCTAssertEqual(ok.id?.intValue, 3)
        XCTAssertNil(ok.method)
        XCTAssertNotNil(ok.result?["tools"])

        let err = try dec.decode(RPCIncoming.self,
            from: Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"Method not found"}}"#.utf8))
        XCTAssertEqual(err.error?.code, -32601)

        // Нотификация сервера: есть method → НЕ ответ (транспорт игнорирует).
        let notification = try dec.decode(RPCIncoming.self,
            from: Data(#"{"jsonrpc":"2.0","method":"notifications/message","params":{}}"#.utf8))
        XCTAssertEqual(notification.method, "notifications/message")
        XCTAssertNil(notification.id?.intValue)
    }

    func testQualifyNameIsSafeAndPrefixed() {
        var server = MCPServer()
        server.name = "Jira Cloud!"
        let qualified = MCPManager.qualify(server: server, tool: "search_issues")
        XCTAssertEqual(qualified, "jira_cloud__search_issues")
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        XCTAssertTrue(qualified.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertLessThanOrEqual(qualified.count, 64)
    }
}

// MARK: - Конверсия схем

final class ToolSchemaConversionTests: XCTestCase {

    private let tool = ToolDefinition(
        name: "jira__create_issue",
        description: "Создать задачу",
        schema: .object([
            "type": .string("object"),
            "$schema": .string("http://json-schema.org/draft-07/schema#"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "title": .object(["type": .string("string"),
                                  "$comment": .string("мусорное поле")]),
                "labels": .object(["type": .string("array"),
                                   "items": .object(["type": .string("string"),
                                                     "additionalProperties": .bool(false)])])
            ]),
            "required": .array([.string("title")])
        ]))

    func testOpenAIToolConversion() {
        let converted = ToolSchemaConversion.openAITool(tool)
        XCTAssertEqual(converted["type"]?.stringValue, "function")
        let function = converted["function"]
        XCTAssertEqual(function?["name"]?.stringValue, "jira__create_issue")
        XCTAssertEqual(function?["description"]?.stringValue, "Создать задачу")
        // Схема уходит как есть (OpenAI ест полный JSON Schema).
        XCTAssertEqual(function?["parameters"]?["properties"]?["title"]?["type"]?.stringValue,
                       "string")
    }

    func testOpenAIToolNonObjectSchemaBecomesEmptyObject() {
        let broken = ToolDefinition(name: "t", description: "", schema: .string("мусор"))
        let converted = ToolSchemaConversion.openAITool(broken)
        XCTAssertEqual(converted["function"]?["parameters"]?["type"]?.stringValue, "object")
    }

    func testGeminiConversionStripsUnsupportedKeys() {
        let declaration = ToolSchemaConversion.geminiFunctionDeclaration(tool)
        XCTAssertEqual(declaration["name"]?.stringValue, "jira__create_issue")
        let parameters = declaration["parameters"]
        // Запрещённые Gemini ключи вырезаны на всех уровнях.
        XCTAssertNil(parameters?["$schema"])
        XCTAssertNil(parameters?["additionalProperties"])
        XCTAssertNil(parameters?["properties"]?["title"]?["$comment"])
        XCTAssertNil(parameters?["properties"]?["labels"]?["items"]?["additionalProperties"])
        // Разрешённые — сохранены.
        XCTAssertEqual(parameters?["type"]?.stringValue, "object")
        XCTAssertEqual(parameters?["required"]?.arrayValue?.first?.stringValue, "title")
        XCTAssertEqual(parameters?["properties"]?["labels"]?["items"]?["type"]?.stringValue,
                       "string")
    }
}

// MARK: - Tool-use цикл

/// Мок-провайдер: отдаёт заранее заготовленные шаги по очереди.
private final class ScriptedToolProvider: ToolCapableChatProvider {
    var steps: [ToolLoopStep]
    private(set) var receivedMessages: [[ToolAwareMessage]] = []
    private(set) var forceTextFlags: [Bool] = []

    init(steps: [ToolLoopStep]) { self.steps = steps }

    func sendWithTools(_ messages: [ToolAwareMessage],
                       settings: ChatSettings,
                       tools: [ToolDefinition],
                       forceText: Bool) async throws -> ToolLoopStep {
        receivedMessages.append(messages)
        forceTextFlags.append(forceText)
        guard !steps.isEmpty else { return ToolLoopStep(text: "пусто", toolCalls: [], usage: nil) }
        return steps.removeFirst()
    }
}

final class ToolUseLoopTests: XCTestCase {
    private let tools = [ToolDefinition(name: "fs__read", description: "", schema: .object([:]))]
    private let settings = ChatSettings(model: "test")

    func testSingleStepNoTools() async throws {
        let provider = ScriptedToolProvider(steps: [
            ToolLoopStep(text: "Просто ответ", toolCalls: [],
                         usage: ChatUsage(promptTokens: 5, completionTokens: 7, totalTokens: 12))
        ])
        let outcome = try await ToolUseLoop.run(
            provider: provider, settings: settings,
            messages: [ToolAwareMessage(role: .user, content: "вопрос")],
            tools: tools) { _, _ in XCTFail("инструменты не запрашивались"); return "" }
        XCTAssertEqual(outcome.text, "Просто ответ")
        XCTAssertEqual(outcome.transcript, [])
        XCTAssertEqual(outcome.usage?.totalTokens, 12)
    }

    func testTwoStepToolScenario() async throws {
        let provider = ScriptedToolProvider(steps: [
            ToolLoopStep(text: nil,
                         toolCalls: [ToolCallRequest(id: "call_1", name: "fs__read",
                                                     argumentsJSON: #"{"path":"a.txt"}"#)],
                         usage: ChatUsage(promptTokens: 10, completionTokens: 2, totalTokens: 12)),
            ToolLoopStep(text: "В файле: привет", toolCalls: [],
                         usage: ChatUsage(promptTokens: 20, completionTokens: 5, totalTokens: 25))
        ])
        var executed: [(String, String)] = []
        let outcome = try await ToolUseLoop.run(
            provider: provider, settings: settings,
            messages: [ToolAwareMessage(role: .user, content: "прочитай a.txt")],
            tools: tools) { name, args in
            executed.append((name, args))
            return "привет"
        }
        XCTAssertEqual(outcome.text, "В файле: привет")
        XCTAssertEqual(executed.count, 1)
        XCTAssertEqual(executed[0].0, "fs__read")
        // Транскрипт вызова записан.
        XCTAssertEqual(outcome.transcript.count, 1)
        XCTAssertEqual(outcome.transcript[0].name, "fs__read")
        XCTAssertEqual(outcome.transcript[0].result, "привет")
        XCTAssertTrue(outcome.transcript[0].ok)
        // Токены двух шагов просуммированы.
        XCTAssertEqual(outcome.usage?.totalTokens, 37)
        // Второй запрос содержит assistant(tool_calls) + tool(результат).
        let second = provider.receivedMessages[1]
        XCTAssertEqual(second[second.count - 2].role, .assistant)
        XCTAssertEqual(second[second.count - 2].toolCalls.first?.id, "call_1")
        XCTAssertEqual(second.last?.role, .tool)
        XCTAssertEqual(second.last?.content, "привет")
        XCTAssertEqual(second.last?.toolCallID, "call_1")
    }

    func testIterationLimitForcesTextOnLastStep() async throws {
        // Модель бесконечно просит инструменты — на последней итерации цикл
        // форсирует текст (forceText=true) и берёт что есть.
        let endlessCall = ToolLoopStep(
            text: nil,
            toolCalls: [ToolCallRequest(id: "c", name: "fs__read", argumentsJSON: "{}")],
            usage: nil)
        let provider = ScriptedToolProvider(steps: [
            endlessCall, endlessCall,
            ToolLoopStep(text: "финальный ответ", toolCalls: [], usage: nil)
        ])
        let outcome = try await ToolUseLoop.run(
            provider: provider, settings: settings,
            messages: [ToolAwareMessage(role: .user, content: "в")],
            tools: tools, maxIterations: 3) { _, _ in "результат" }
        XCTAssertEqual(outcome.text, "финальный ответ")
        XCTAssertEqual(provider.forceTextFlags, [false, false, true],
                       "последняя итерация — tool_choice=none")
        XCTAssertEqual(outcome.transcript.count, 2)
    }

    func testServerErrorSurfacesAsErrorResultAndLoopContinues() async throws {
        // Падение сервера посреди вызова: execute возвращает ERROR-текст —
        // модель видит его и отвечает словами (не молча).
        let provider = ScriptedToolProvider(steps: [
            ToolLoopStep(text: nil,
                         toolCalls: [ToolCallRequest(id: "c1", name: "jira__search",
                                                     argumentsJSON: "{}")],
                         usage: nil),
            ToolLoopStep(text: "Jira недоступна, попробуйте позже.", toolCalls: [], usage: nil)
        ])
        let outcome = try await ToolUseLoop.run(
            provider: provider, settings: settings,
            messages: [ToolAwareMessage(role: .user, content: "найди задачи")],
            tools: tools) { _, _ in
            "ERROR: Сбой MCP-процесса: сервер упал"
        }
        XCTAssertEqual(outcome.text, "Jira недоступна, попробуйте позже.")
        XCTAssertFalse(outcome.transcript[0].ok, "вызов помечен ошибочным")
        XCTAssertTrue(outcome.transcript[0].result.hasPrefix("ERROR"))
    }

    /// Регрессия (задача 35): пустой финальный текст при непустом транскрипте
    /// больше НЕ выбрасывает emptyResponse — берётся последний непустой текст
    /// ассистента из цикла, транскрипт не теряется.
    func testEmptyFinalTextFallsBackToLastAssistantText() async throws {
        let provider = ScriptedToolProvider(steps: [
            ToolLoopStep(text: "Промежуточный вывод",
                         toolCalls: [ToolCallRequest(id: "c1", name: "fs__read",
                                                     argumentsJSON: "{}")],
                         usage: nil),
            ToolLoopStep(text: "", toolCalls: [], usage: nil),
        ])
        let outcome = try await ToolUseLoop.run(
            provider: provider, settings: settings,
            messages: [ToolAwareMessage(role: .user, content: "в")],
            tools: tools) { _, _ in "данные" }
        XCTAssertEqual(outcome.text, "Промежуточный вывод")
        XCTAssertEqual(outcome.transcript.count, 1, "транскрипт сохранён")
    }

    /// Пустой текст при непустом транскрипте и без текста в цикле —
    /// отдаётся пустой текст с транскриптом (решает вызывающий), не ошибка.
    func testEmptyTextWithTranscriptReturnsTranscript() async throws {
        let provider = ScriptedToolProvider(steps: [
            ToolLoopStep(text: nil,
                         toolCalls: [ToolCallRequest(id: "c1", name: "fs__read",
                                                     argumentsJSON: "{}")],
                         usage: nil),
            ToolLoopStep(text: nil, toolCalls: [], usage: nil),
        ])
        let outcome = try await ToolUseLoop.run(
            provider: provider, settings: settings,
            messages: [ToolAwareMessage(role: .user, content: "в")],
            tools: tools) { _, _ in "данные" }
        XCTAssertEqual(outcome.text, "")
        XCTAssertEqual(outcome.transcript.count, 1)
    }

    /// Совсем пустой ответ (ни текста, ни вызовов) по-прежнему ошибка.
    func testFullyEmptyResponseStillThrows() async throws {
        let provider = ScriptedToolProvider(steps: [
            ToolLoopStep(text: nil, toolCalls: [], usage: nil),
        ])
        do {
            _ = try await ToolUseLoop.run(
                provider: provider, settings: settings,
                messages: [ToolAwareMessage(role: .user, content: "в")],
                tools: tools) { _, _ in "" }
            XCTFail("ожидали emptyResponse")
        } catch let error as LLMError {
            guard case .emptyResponse = error else {
                return XCTFail("не та ошибка: \(error)")
            }
        }
    }
}

// MARK: - Конфиг серверов

final class MCPServerConfigTests: XCTestCase {

    func testParseClaudeConfig() {
        let json = """
        {"mcpServers": {
            "filesystem": {"command": "npx",
                           "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                           "env": {"LOG": "1"}},
            "jira": {"command": "npx", "args": ["-y", "mcp-remote", "https://mcp.atlassian.com/v1/sse"]}
        }}
        """
        let servers = MCPServer.parseClaudeConfig(json)
        XCTAssertEqual(servers.map(\.name), ["filesystem", "jira"])
        XCTAssertEqual(servers[0].args.count, 3)
        XCTAssertEqual(servers[0].env["LOG"], "1")
        XCTAssertTrue(servers.allSatisfy(\.enabled))
        XCTAssertEqual(MCPServer.parseClaudeConfig("не json"), [])
    }

    func testKeychainEnvResolution() {
        var server = MCPServer()
        server.env = ["JIRA_TOKEN": "keychain:jira-token",
                      "PLAIN": "как есть"]
        let env = MCPEnv.childEnvironment(server) { account in
            account == "jira-token" ? "секрет-из-keychain" : nil
        }
        XCTAssertEqual(env["JIRA_TOKEN"], "секрет-из-keychain",
                       "keychain:-значение резолвится через KeyStore")
        XCTAssertEqual(env["PLAIN"], "как есть")
        XCTAssertNotNil(env["PATH"])
    }

    func testKeychainMissingKeyGivesEmptyString() {
        XCTAssertEqual(MCPEnv.resolveSecret("keychain:нет-такого", keyLookup: { _ in nil }), "")
        XCTAssertEqual(MCPEnv.resolveSecret("обычное", keyLookup: { _ in nil }), "обычное")
    }

    func testServerMigrationFromMinimalJSON() throws {
        let json = #"[{"name": "старый", "args": ["-y", "x"]}]"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let servers = MCPServerStore.load(from: url)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].command, "npx", "нет команды → дефолт npx")
        XCTAssertTrue(servers[0].enabled)
    }

    func testChatConfigurationMCPServersMigration() throws {
        // Чат из задачи 14 (без MCP-поля) грузится с пустым набором серверов.
        let json = #"[{"title": "Т", "configuration": {"ragEnabled": true}}]"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let chats = ChatPersistence.load(from: url)
        XCTAssertEqual(chats[0].configuration.enabledMCPServerIDs, [])
        XCTAssertTrue(chats[0].configuration.ragEnabled)
    }

    func testToolCallDisplayPersistsInMessage() throws {
        var chat = Chat()
        var message = ChatMessage(role: .assistant, content: "готово")
        message.toolCalls = [ToolCallDisplay(name: "jira__search",
                                             argumentsJSON: #"{"q":"релиз"}"#,
                                             result: "3 задачи", ok: true)]
        chat.messages = [message]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        ChatPersistence.save([chat], to: url)
        let loaded = ChatPersistence.load(from: url)
        XCTAssertEqual(loaded[0].messages[0].toolCalls?.first?.name, "jira__search")
        XCTAssertEqual(loaded[0].messages[0].toolCalls?.first?.ok, true)
    }
}

// MARK: - Ollama tool-парсер

final class OllamaToolParsingTests: XCTestCase {

    func testParseChatToolResponseWithObjectArguments() throws {
        // Ollama отдаёт arguments ОБЪЕКТОМ и без id — id синтезируется.
        let json = """
        {"message": {"role": "assistant", "content": "",
                     "tool_calls": [{"function": {"name": "fs__read",
                                                  "arguments": {"path": "a.txt"}}}]},
         "prompt_eval_count": 10, "eval_count": 4, "done": true}
        """
        let step = try OllamaParsing.parseChatToolResponse(Data(json.utf8))
        XCTAssertEqual(step.toolCalls.count, 1)
        XCTAssertEqual(step.toolCalls[0].id, "call_0")
        XCTAssertEqual(step.toolCalls[0].name, "fs__read")
        XCTAssertEqual(JSONValue.parse(step.toolCalls[0].argumentsJSON)?["path"]?.stringValue,
                       "a.txt")
        XCTAssertEqual(step.usage?.totalTokens, 14)
    }

    func testParseChatToolResponsePlainText() throws {
        let json = #"{"message": {"role": "assistant", "content": "просто текст"}, "done": true}"#
        let step = try OllamaParsing.parseChatToolResponse(Data(json.utf8))
        XCTAssertEqual(step.text, "просто текст")
        XCTAssertEqual(step.toolCalls, [])
    }
}
