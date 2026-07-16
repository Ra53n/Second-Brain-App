// ProjectToolsProvider.swift — владелец инструментов проекта (задача 21).
//
// Связывает настройку projectRepoPath с рантаймом: лениво создаёт пару
// (ToolRegistry, ToolExecutor) для текущего пути и пересоздаёт её при смене
// пути в настройках (кэш по пути). Живёт в AppModel; чат обращается через
// замыкания ProjectToolsBridge (wireProjectTools в ContentView).

import Foundation

/// Лениво создаёт и кэширует исполнитель инструментов для выбранного репозитория.
@MainActor
final class ProjectToolsProvider {
    private let settingsStore: SettingsStore
    private var cached: (path: String, registry: ToolRegistry, executor: ToolExecutor)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Регистратор+исполнитель для текущего пути настроек; nil — путь не задан.
    func current() -> (registry: ToolRegistry, executor: ToolExecutor)? {
        let path = settingsStore.settings.projectRepoPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            cached = nil
            return nil
        }
        if let cached, cached.path == path {
            return (cached.registry, cached.executor)
        }
        let root = URL(fileURLWithPath: path)
        let registry = ToolRegistry.projectTools(repoRoot: root)
        let executor = ToolExecutor(registry: registry, repoRoot: root)
        cached = (path, registry, executor)
        return (registry, executor)
    }
}
