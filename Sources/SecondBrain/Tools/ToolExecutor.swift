// ToolExecutor.swift — исполнитель встроенных инструментов (задача 21).
//
// Один общий исполнитель: находит тулзу в регистраторе по имени вызова,
// собирает ToolContext из аргументов модели и корня репозитория, выполняет
// и возвращает результат текстом. Ошибки любого рода — строкой «ERROR: …»
// (конвенция ToolUseLoop: модель видит ошибку и может скорректироваться).

import Foundation

/// Исполнитель встроенных инструментов, привязанный к корню репозитория.
actor ToolExecutor {
    private let registry: ToolRegistry
    private let repoRoot: URL

    init(registry: ToolRegistry, repoRoot: URL) {
        self.registry = registry
        self.repoRoot = repoRoot
    }

    /// Выполняет вызов модели: имя инструмента + JSON-строка аргументов.
    /// fileOps — контекст файловых операций чата (задача 39); nil — вызов
    /// вне чата, write-инструменты откажут.
    func execute(name: String, argumentsJSON: String,
                 fileOps: FileOpsContext? = nil) async -> String {
        guard let tool = registry.findByName(name) else {
            return "ERROR: неизвестный инструмент «\(name)»"
        }
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments: JSONValue
        if trimmed.isEmpty {
            arguments = .object([:])
        } else if let parsed = JSONValue.parse(trimmed) {
            arguments = parsed
        } else {
            return "ERROR: аргументы «\(name)» не являются корректным JSON"
        }
        let context = ToolContext(repoRoot: repoRoot, arguments: arguments,
                                  fileOps: fileOps)
        return await tool.execute(context).text
    }
}
