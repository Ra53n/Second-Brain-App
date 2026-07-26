// ProjectToolsBridge.swift — мост ChatViewModel к встроенным инструментам проекта
// (задачи 21, 39, вынесено в 76).

import Foundation

extension ChatViewModel {
    /// Мост встроенных инструментов проекта (задачи 21, 39). Маршрутизация в
    /// send(): вызовы с именами из tools() идут сюда, остальные — в MCP
    /// (имена не пересекаются: MCP-имена всегда содержат «__»). Первый
    /// параметр всюду — projectRootPath чата (nil = глобальная настройка).
    struct ProjectToolsBridge {
        /// Каталог задан (override чата либо настройки) — видимость меню.
        var available: (String?) -> Bool
        var tools: (String?) -> [ToolDefinition]
        /// Эффективный корень (для превью diff'ов и директивы промпта).
        var rootURL: (String?) -> URL?
        /// (rootOverride, имя, аргументы, файловый контекст чата) → результат.
        var execute: (String?, String, String, FileOpsContext?) async -> String
    }
}
