// ProviderToolSupportTests.swift — тесты DTO провайдеров: OpenAIToolRequestBody,
// ToolCallDTO, OpenAIToolResponse, OllamaClient.toolMessageJSON. Без сети,
// только encode/decode на структурах и фикстурах JSON.

import XCTest
@testable import SecondBrain

final class ProviderToolSupportTests: XCTestCase {

    // MARK: - OpenAIToolRequestBody кодирование

    func testOpenAIToolRequestBodyWithTools() throws {
        let tool = ToolDefinition(
            name: "search_issues",
            description: "Search for issues",
            schema: .object(["type": .string("object"),
                            "properties": .object(["q": .object(["type": .string("string")])])])
        )
        let messages = [ToolAwareMessage(role: .user, content: "найди задачи")]
        let body = OpenAIToolRequestBody(
            model: "gpt-4o-mini",
            messages: messages.map(OpenAIToolRequestBody.Message.init),
            temperature: 0.7,
            max_tokens: 100,
            tools: [ToolSchemaConversion.openAITool(tool)],
            tool_choice: "auto"
        )
        let encoded = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(json["temperature"] as? Double, 0.7)
        XCTAssertEqual(json["max_tokens"] as? Int, 100)
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["tool_choice"] as? String, "auto")
        XCTAssertNotNil(json["tools"])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["type"] as? String, "function")
    }

    func testOpenAIToolRequestBodyWithoutTools() throws {
        let messages = [ToolAwareMessage(role: .user, content: "просто вопрос")]
        let body = OpenAIToolRequestBody(
            model: "gpt-4o-mini",
            messages: messages.map(OpenAIToolRequestBody.Message.init),
            temperature: 0.5,
            max_tokens: 50,
            tools: nil,
            tool_choice: nil
        )
        let encoded = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNil(json["tools"], "tools должны быть опущены если nil")
        XCTAssertNil(json["tool_choice"], "tool_choice должна быть опущена если nil")
        XCTAssertEqual(json["stream"] as? Bool, false)
    }

    func testOpenAIToolRequestBodyWithEmptyToolsList() throws {
        let messages = [ToolAwareMessage(role: .user, content: "вопрос")]
        // В реальном коде OpenAIProvider преобразует пустой список в nil перед кодированием,
        // но здесь мы тестируем, что структура самостоятельно обработает пустой список.
        let body = OpenAIToolRequestBody(
            model: "gpt-4o-mini",
            messages: messages.map(OpenAIToolRequestBody.Message.init),
            temperature: 0.5,
            max_tokens: 50,
            tools: [], // пустой массив
            tool_choice: nil
        )
        let encoded = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        // Пустой массив кодируется как пустой массив, не как nil
        let tools = json["tools"] as? [Any]
        XCTAssertEqual(tools?.count ?? 0, 0)
        XCTAssertNil(json["tool_choice"])
    }

    // MARK: - OpenAIToolRequestBody.Message с tool_calls

    func testMessageWithToolCallsEncoded() throws {
        var message = ToolAwareMessage(role: .assistant, content: "обработка")
        message.toolCalls = [
            ToolCallRequest(id: "call_1", name: "search_issues", argumentsJSON: #"{"q":"критична"}"#),
            ToolCallRequest(id: "call_2", name: "get_issue", argumentsJSON: #"{"id":"123"}"#)
        ]
        let dto = OpenAIToolRequestBody.Message(message)
        let encoded = try JSONEncoder().encode(dto)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(json["role"] as? String, "assistant")
        XCTAssertEqual(json["content"] as? String, "обработка")
        let calls = try XCTUnwrap(json["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0]["id"] as? String, "call_1")
        XCTAssertEqual(calls[0]["type"] as? String, "function")
        let function0 = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(function0["name"] as? String, "search_issues")
        XCTAssertEqual(function0["arguments"] as? String, #"{"q":"критична"}"#)
    }

    func testMessageWithoutToolCallsHasNilField() throws {
        var message = ToolAwareMessage(role: .assistant, content: "ответ")
        message.toolCalls = [] // пусто
        let dto = OpenAIToolRequestBody.Message(message)
        let encoded = try JSONEncoder().encode(dto)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNil(json["tool_calls"], "пустые tool_calls кодируются как nil")
    }

    func testToolCallDTOEncodedCorrectly() throws {
        let dto = ToolCallDTO(
            ToolCallRequest(id: "call_x", name: "run_test", argumentsJSON: #"{"key":"value"}"#)
        )
        let encoded = try JSONEncoder().encode(dto)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(json["id"] as? String, "call_x")
        XCTAssertEqual(json["type"] as? String, "function")
        let function = try XCTUnwrap(json["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "run_test")
        XCTAssertEqual(function["arguments"] as? String, #"{"key":"value"}"#)
    }

    // MARK: - OpenAIToolResponse декодирование

    func testDecodesResponseWithToolCalls() throws {
        let json = """
        {
          "choices": [{
            "message": {
              "content": "Я выполню поиск",
              "tool_calls": [
                {
                  "id": "call_1",
                  "type": "function",
                  "function": {
                    "name": "search_issues",
                    "arguments": "{\\"q\\":\\"критична\\"}"
                  }
                }
              ]
            }
          }],
          "usage": {
            "prompt_tokens": 20,
            "completion_tokens": 15,
            "total_tokens": 35
          }
        }
        """
        let decoded = try JSONDecoder().decode(OpenAIToolResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.choices.count, 1)
        let message = decoded.choices[0].message
        XCTAssertEqual(message.content, "Я выполню поиск")
        XCTAssertEqual(message.tool_calls?.count, 1)
        XCTAssertEqual(message.tool_calls?[0].id, "call_1")
        XCTAssertEqual(message.tool_calls?[0].function.name, "search_issues")
        XCTAssertEqual(message.tool_calls?[0].function.arguments, "{\"q\":\"критична\"}")
        XCTAssertEqual(decoded.usage?.prompt_tokens, 20)
        XCTAssertEqual(decoded.usage?.total_tokens, 35)
    }

    func testDecodesResponseWithoutToolCalls() throws {
        let json = """
        {
          "choices": [{
            "message": {
              "content": "Просто текстовый ответ"
            }
          }],
          "usage": {
            "prompt_tokens": 10,
            "completion_tokens": 5,
            "total_tokens": 15
          }
        }
        """
        let decoded = try JSONDecoder().decode(OpenAIToolResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.choices.count, 1)
        XCTAssertEqual(decoded.choices[0].message.content, "Просто текстовый ответ")
        XCTAssertNil(decoded.choices[0].message.tool_calls)
        XCTAssertEqual(decoded.usage?.total_tokens, 15)
    }

    func testDecodesResponseWithMultipleToolCalls() throws {
        let json = """
        {
          "choices": [{
            "message": {
              "content": null,
              "tool_calls": [
                {
                  "id": "call_1",
                  "type": "function",
                  "function": {
                    "name": "search_issues",
                    "arguments": "{\\"q\\":\\"баг\\"}"
                  }
                },
                {
                  "id": "call_2",
                  "type": "function",
                  "function": {
                    "name": "get_issue",
                    "arguments": "{\\"id\\":\\"456\\"}"
                  }
                }
              ]
            }
          }]
        }
        """
        let decoded = try JSONDecoder().decode(OpenAIToolResponse.self, from: Data(json.utf8))

        let message = decoded.choices[0].message
        XCTAssertNil(message.content)
        XCTAssertEqual(message.tool_calls?.count, 2)
        XCTAssertEqual(message.tool_calls?[0].function.name, "search_issues")
        XCTAssertEqual(message.tool_calls?[1].function.name, "get_issue")
    }

    func testDecodesResponseWithoutUsage() throws {
        let json = """
        {
          "choices": [{
            "message": {
              "content": "ответ"
            }
          }]
        }
        """
        let decoded = try JSONDecoder().decode(OpenAIToolResponse.self, from: Data(json.utf8))

        XCTAssertNil(decoded.usage)
        XCTAssertEqual(decoded.choices[0].message.content, "ответ")
    }

    // MARK: - Ollama toolMessageJSON преобразование

    func testOllamaToolMessageJSONWithoutCalls() throws {
        let message = ToolAwareMessage(role: .user, content: "привет")
        let value = OllamaClient.toolMessageJSON(message)

        let object = value.objectValue
        XCTAssertEqual(object?["role"]?.stringValue, "user")
        XCTAssertEqual(object?["content"]?.stringValue, "привет")
        XCTAssertNil(object?["tool_calls"])
    }

    func testOllamaToolMessageJSONWithToolCalls() throws {
        var message = ToolAwareMessage(role: .assistant, content: "")
        message.toolCalls = [
            ToolCallRequest(id: "call_1", name: "search", argumentsJSON: #"{"q":"тест"}"#)
        ]
        let value = OllamaClient.toolMessageJSON(message)

        let object = value.objectValue
        XCTAssertEqual(object?["role"]?.stringValue, "assistant")
        let calls = object?["tool_calls"]?.arrayValue
        XCTAssertEqual(calls?.count, 1)
        let call = calls?[0].objectValue
        let function = call?["function"]?.objectValue
        XCTAssertEqual(function?["name"]?.stringValue, "search")
        // arguments должны быть объектом, не строкой
        XCTAssertEqual(function?["arguments"]?.objectValue?["q"]?.stringValue, "тест")
    }

    func testOllamaToolMessageJSONWithInvalidJSON() throws {
        var message = ToolAwareMessage(role: .assistant, content: "")
        message.toolCalls = [
            ToolCallRequest(id: "c1", name: "t", argumentsJSON: "не json")
        ]
        let value = OllamaClient.toolMessageJSON(message)

        let object = value.objectValue
        let calls = object?["tool_calls"]?.arrayValue
        let call = calls?[0].objectValue
        let function = call?["function"]?.objectValue
        // При ошибке парсинга — пустой объект
        XCTAssertEqual(function?["arguments"]?.objectValue, [:])
    }

    // MARK: - Roundtrip ToolCallDTO

    func testToolCallDTOEncodeDecodeRoundtrip() throws {
        let original = ToolCallDTO(
            ToolCallRequest(id: "call_123", name: "jira__search", argumentsJSON: #"{"q":"критично"}"#)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolCallDTO.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.function.name, original.function.name)
        XCTAssertEqual(decoded.function.arguments, original.function.arguments)
    }

    // MARK: - Сложный случай: вложенные параметры со структурой

    // Пересекается с ToolSchemaConversionTests.testOpenAIToolConversion (MCPTests.swift)
    // по проверяемой функции (ToolSchemaConversion.openAITool), но другой уровень:
    // там — сама конвертация схемы, здесь — полный encode-пайплайн через
    // OpenAIToolRequestBody (то, что реально уходит в HTTP-тело запроса).
    func testOpenAIToolWithComplexParameterSchema() throws {
        let complexTool = ToolDefinition(
            name: "create_task",
            description: "Создать задачу с вложенными полями",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string")]),
                    "assignee": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id": .object(["type": .string("string")]),
                            "email": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("id")])
                    ]),
                    "tags": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ]),
                "required": .array([.string("title")])
            ])
        )

        let body = OpenAIToolRequestBody(
            model: "gpt-4o",
            messages: [ToolAwareMessage(role: .user, content: "создай")].map(OpenAIToolRequestBody.Message.init),
            temperature: 0.8,
            max_tokens: 200,
            tools: [ToolSchemaConversion.openAITool(complexTool)],
            tool_choice: "auto"
        )

        let encoded = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])

        // Проверяем, что вложенная структура сохранена
        XCTAssertNotNil(properties["assignee"])
        let assignee = try XCTUnwrap(properties["assignee"] as? [String: Any])
        XCTAssertEqual(assignee["type"] as? String, "object")
        let assigneeProps = try XCTUnwrap(assignee["properties"] as? [String: Any])
        XCTAssertNotNil(assigneeProps["id"])
        XCTAssertNotNil(assigneeProps["email"])

        // Проверяем required и items
        XCTAssertEqual(parameters["required"] as? [String], ["title"])
        let tags = try XCTUnwrap(properties["tags"] as? [String: Any])
        let items = try XCTUnwrap(tags["items"] as? [String: Any])
        XCTAssertEqual(items["type"] as? String, "string")
    }

    // MARK: - Опциональные поля: не в required

    func testOpenAIToolOptionalFieldNotInRequiredList() throws {
        let tool = ToolDefinition(
            name: "update_task",
            description: "Обновить задачу",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "note": .object(["type": .string("string")]) // не в required — опционально
                ]),
                "required": .array([.string("id")])
            ])
        )
        let body = OpenAIToolRequestBody(
            model: "gpt-4o-mini",
            messages: [ToolAwareMessage(role: .user, content: "обнови")].map(OpenAIToolRequestBody.Message.init),
            temperature: 0.5,
            max_tokens: 50,
            tools: [ToolSchemaConversion.openAITool(tool)],
            tool_choice: "auto"
        )
        let encoded = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])

        let required = try XCTUnwrap(parameters["required"] as? [String])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        // Поле присутствует в схеме параметров, но не входит в required —
        // конвертация ничего не домысливает за MCP-сервер, required переносится как есть.
        XCTAssertNotNil(properties["note"])
        XCTAssertTrue(required.contains("id"))
        XCTAssertFalse(required.contains("note"))
    }

    // MARK: - Enum-параметр

    // ToolSchemaConversion.openAITool — сквозной pass-through всей схемы (см.
    // ToolUse.swift:112-124): нет специальной обработки по типу поля (string/enum/
    // object/array — все проходят одним и тем же путём через JSONValue). Поэтому
    // отдельного алгоритма для enum нет и тест короткий — он лишь фиксирует, что
    // enum-константы не теряются и не переупорядочиваются при кодировании.
    func testOpenAIToolWithEnumParameterIsPassthrough() throws {
        let tool = ToolDefinition(
            name: "set_status",
            description: "Сменить статус",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "status": .object([
                        "type": .string("string"),
                        "enum": .array([.string("open"), .string("in_progress"), .string("done")])
                    ])
                ]),
                "required": .array([.string("status")])
            ])
        )
        let converted = ToolSchemaConversion.openAITool(tool)
        let encoded = try JSONEncoder().encode(converted)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let function = try XCTUnwrap(json["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let status = try XCTUnwrap(properties["status"] as? [String: Any])

        XCTAssertEqual(status["enum"] as? [String], ["open", "in_progress", "done"])
    }

    // MARK: - Пустая схема параметров (MCP-тул без аргументов)

    func testOpenAIToolWithEmptyParameterSchemaProperties() throws {
        // Частый реальный случай: MCP-тул без аргументов присылает валидный
        // объект-схему с пустым properties (не путать с "пустым списком tools" —
        // см. testOpenAIToolRequestBodyWithEmptyToolsList).
        let tool = ToolDefinition(
            name: "list_projects",
            description: "Список проектов",
            schema: .object(["type": .string("object"), "properties": .object([:])])
        )
        let body = OpenAIToolRequestBody(
            model: "gpt-4o-mini",
            messages: [ToolAwareMessage(role: .user, content: "список")].map(OpenAIToolRequestBody.Message.init),
            temperature: 0.5,
            max_tokens: 50,
            tools: [ToolSchemaConversion.openAITool(tool)],
            tool_choice: "auto"
        )
        let encoded = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])

        XCTAssertEqual(parameters["type"] as? String, "object")
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertTrue(properties.isEmpty)
        XCTAssertNil(parameters["required"], "required отсутствует, если MCP-сервер его не прислал")
    }
}
