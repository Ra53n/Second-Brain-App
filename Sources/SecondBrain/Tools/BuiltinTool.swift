// BuiltinTool.swift — контракт встроенных инструментов чата (задача 21).
//
// Архитектура: name + description + parameters — информация об инструменте
// для LLM (parameters — JSON Schema аргументов для валидации на стороне
// модели), execute — собственно логика. Каждый инструмент — отдельный класс;
// регистрируются в ToolRegistry, исполняются через общий ToolExecutor.
//
// Имена встроенных инструментов НЕ содержат «__»: qualified-имена MCP всегда
// вида «slug__tool» (MCPManager.qualify), поэтому пространства имён не
// пересекаются по построению — закреплено тестом.

import Foundation

/// Контекст одного выполнения инструмента: разобранные аргументы вызова
/// + окружение (корень репозитория, выбранного в настройках).
struct ToolContext: Sendable {
    /// Корень репозитория/папки, по которой ходят инструменты.
    let repoRoot: URL
    /// Аргументы вызова от модели; `{}` при пустых.
    let arguments: JSONValue

    /// Строковый аргумент по ключу.
    func input(_ key: String) -> String? { arguments[key]?.stringValue }
    /// Целочисленный аргумент по ключу (double приводится к Int).
    func intInput(_ key: String) -> Int? { arguments[key]?.intValue }
}

/// Результат инструмента. Ошибки — тоже текстом с префиксом «ERROR: »
/// (конвенция ToolUseLoop: модель видит ошибку и может отреагировать).
struct ToolResult: Sendable, Equatable {
    let text: String
    let isError: Bool

    static func ok(_ text: String) -> ToolResult {
        ToolResult(text: text, isError: false)
    }

    static func error(_ message: String) -> ToolResult {
        ToolResult(text: "ERROR: \(message)", isError: true)
    }
}

/// Встроенный инструмент чата. name/description/parameters — для LLM,
/// execute — логика. Каждый инструмент — отдельный класс.
protocol BuiltinTool: Sendable {
    /// Имя функции для модели. Без «__» — исключает коллизию с MCP.
    var name: String { get }
    var description: String { get }
    /// JSON Schema аргументов (объект; пустой объект — без аргументов).
    var parameters: JSONValue { get }

    func execute(_ ctx: ToolContext) async -> ToolResult
}

extension BuiltinTool {
    /// ToolDefinition для tool-use цикла (единый формат с MCP-инструментами).
    var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, schema: parameters)
    }
}

/// Хелперы сборки JSON Schema руками (без словарей-литералов в каждом туле).
enum ToolSchemas {
    /// Схема «объект без аргументов» (требование OpenAI: parameters — объект).
    static let empty: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:])
    ])

    /// Схема-объект с заданными свойствами.
    static func object(_ properties: [String: JSONValue],
                       required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(JSONValue.string))
        }
        return .object(schema)
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
