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

    /// Штатный набор инструментов проекта: обзор git-репозитория и файлов.
    /// GitClient создаётся один на корень — его FIFO-очередь сериализует
    /// параллельные вызовы (второй GitClient на том же репо у SyncViewModel
    /// безопасен: все инструменты здесь read-only).
    static func projectTools(repoRoot: URL) -> ToolRegistry {
        let git = GitClient(repoURL: repoRoot)
        return ToolRegistry(tools: [
            GitBranchesTool(git: git),
            GitStatusTool(git: git),
            GitLogTool(git: git),
            GitDiffTool(git: git),
            ListFilesTool(git: git),
            ReadFileTool()
        ])
    }
}
