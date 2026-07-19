// VaultPath.swift — чистые вычисления путей внутри vault (задача 42).
//
// Здесь живут:
//  - PathSegment — сегмент breadcrumb (url для навигации + имя для показа);
//  - VaultPath   — цепочка сегментов «корень vault → … → файл» для полоски
//                  пути и множество предков для раскрытия дерева (reveal).
//
// Функции не трогают файловую систему: принадлежность файла и его тип
// известны вызывающему (VaultNode), поэтому всё считается по строкам путей
// и тестируется без temp-директорий.

import Foundation

/// Сегмент breadcrumb: URL для навигации + имя для отображения.
struct PathSegment: Identifiable, Equatable {
    let url: URL
    let name: String
    let isDirectory: Bool

    /// Идентичность — по пути, как у VaultNode: переживает перестроение дерева.
    var id: String { url.path }
}

enum VaultPath {

    /// Цепочка сегментов от корня vault (включительно) до url (включительно).
    /// Промежуточные сегменты — всегда папки; тип последнего задаёт
    /// `isDirectory` (сам URL не позволяет отличить файл от папки без ФС).
    /// nil — url вне vault (битый selection, защита от мусорных нотификаций).
    static func segments(for url: URL, isDirectory: Bool, vaultRoot: URL) -> [PathSegment]? {
        let root = vaultRoot.standardizedFileURL
        let target = url.standardizedFileURL
        var result = [PathSegment(url: root, name: root.lastPathComponent, isDirectory: true)]
        if target.path == root.path { return result }
        guard target.path.hasPrefix(root.path + "/") else { return nil }

        // Префикс с "/" отрезан выше, поэтому «/x/NotesBackup» не пройдёт
        // проверку для vault «/x/Notes» — режем строго по границе компонента.
        let components = target.path.dropFirst(root.path.count + 1).split(separator: "/")
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            result.append(PathSegment(
                url: current,
                name: String(component),
                isDirectory: index < components.count - 1 || isDirectory
            ))
        }
        return result
    }

    /// Пути папок-предков url внутри vault — ключи для expandedFolders при
    /// reveal. Без корня (верхний уровень дерева виден всегда) и без самой
    /// цели (раскрывать выбранную папку не нужно — только показать её).
    static func ancestorPaths(of url: URL, within vaultRoot: URL) -> Set<String> {
        let root = vaultRoot.standardizedFileURL
        let target = url.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return [] }

        var result = Set<String>()
        var current = target.deletingLastPathComponent()
        while current.path != root.path, current.path.hasPrefix(root.path + "/") {
            result.insert(current.path)
            current = current.deletingLastPathComponent()
        }
        return result
    }
}
