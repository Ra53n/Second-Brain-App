// SafePath.swift — безопасное разрешение путей внутри корня (задача 21).
//
// Инструменты read_file/list_files получают путь от LLM — считаем его
// недоверенным вводом: нормализация, резолв симлинков и жёсткая проверка,
// что итог не вышел из корня («../», абсолютные пути, симлинк-побег).

import Foundation

enum SafePath {
    /// Разрешает относительный путь строго внутри корня.
    /// nil — путь пустой, абсолютный или выводит за пределы корня.
    static func resolve(_ relative: String, under root: URL) -> URL? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            return nil
        }
        // Симлинки резолвятся у ОБОИХ путей: /tmp → /private/tmp у корня и
        // симлинк-побег внутри candidate ловятся одной префикс-проверкой.
        // У несуществующего файла резолвится существующая часть пути —
        // родительский симлинк наружу тоже не пройдёт.
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = root.appendingPathComponent(trimmed)
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let candidatePath = candidate.path
        guard candidatePath == rootPath
                || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        else { return nil }
        return candidate
    }
}
