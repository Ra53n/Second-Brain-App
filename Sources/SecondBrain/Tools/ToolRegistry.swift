// ToolRegistry.swift — регистратор встроенных инструментов (задача 21).
//
// Единственная задача — хранить зарегистрированные тулзы и отдавать их
// по имени (для исполнителя) и списком определений (для LLM). Набор
// фиксируется при создании: инструменты stateless относительно регистратора.

import Foundation

/// Регистратор встроенных инструментов чата.
final class ToolRegistry: Sendable {
    /// Инструменты в порядке регистрации (порядок виден модели).
    private let ordered: [any BuiltinTool]
    private let byName: [String: any BuiltinTool]

    /// Регистрация набора. Дубликат имени — ошибка программиста: первый
    /// зарегистрированный побеждает (assert в debug).
    init(tools: [any BuiltinTool]) {
        ordered = tools
        var map: [String: any BuiltinTool] = [:]
        for tool in tools {
            assert(map[tool.name] == nil, "дубликат инструмента: \(tool.name)")
            if map[tool.name] == nil { map[tool.name] = tool }
        }
        byName = map
    }

    func findByName(_ name: String) -> (any BuiltinTool)? {
        byName[name]
    }

    var names: Set<String> { Set(byName.keys) }

    /// Определения для tool-use цикла (name + description + parameters).
    func definitions() -> [ToolDefinition] {
        ordered.map(\.definition)
    }

    /// Каталог встроенных инструментов для ОТОБРАЖЕНИЯ (вкладка «Инструменты»
    /// и счётчик чипа, задача 27): имена/описания/схемы не зависят от корня,
    /// поэтому корень — заглушка. GitClient при создании только ищет путь к
    /// git-бинарю, команд не запускает.
    static func projectToolCatalog() -> [ToolDefinition] {
        projectTools(repoRoot: URL(fileURLWithPath: "/")).definitions()
    }

    /// Штатный набор инструментов проекта: обзор git-репозитория, чтение,
    /// поиск, а с задачи 39 — запись/правка/удаление файлов и запуск команд
    /// (разрешение на write/dangerous даёт слой ToolPermissions + approve).
    /// GitClient создаётся один на корень — его FIFO-очередь сериализует
    /// параллельные вызовы.
    static func projectTools(repoRoot: URL) -> ToolRegistry {
        let git = GitClient(repoURL: repoRoot)
        return ToolRegistry(tools: [
            GitBranchesTool(git: git),
            GitStatusTool(git: git),
            GitLogTool(git: git),
            GitDiffTool(git: git),
            ListFilesTool(git: git),
            ReadFileTool(),
            SearchFilesTool(git: git),
            WriteFileTool(),
            EditFileTool(),
            DeleteFileTool(),
            RunCommandTool()
        ])
    }
}
