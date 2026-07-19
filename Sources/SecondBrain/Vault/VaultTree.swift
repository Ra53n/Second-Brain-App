// VaultTree.swift — модель дерева vault и его построение с диска.
//
// Здесь живут:
//  - VaultNode  — узел дерева (файл или папка), Identifiable по пути;
//  - VaultTree  — рекурсивное построение дерева из директории с сортировкой
//                 «папки сначала» и фильтрацией dot-элементов (.obsidian, .git…);
//  - VaultID    — стабильный идентификатор vault (hash пути) для папок
//                 производных данных в Application Support (инвариант №1:
//                 индексы живут ВНЕ vault и пересоздаваемы).
//
// Дерево — иммутабельный снимок: любое изменение на диске (своё или внешнее
// через FSEvents) приводит к полному перестроению. Для vault в тысячи заметок
// это дёшево и избавляет от инкрементальной синхронизации состояния.

import Foundation
import CryptoKit

/// Узел дерева vault: файл или папка. Идентичность — по абсолютному пути,
/// поэтому selection в UI переживает перестроение дерева.
struct VaultNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Дети папки (отсортированы); у файла — nil (контракт List(children:)).
    var children: [VaultNode]?

    var id: String { url.path }

    /// Поиск узла по URL в поддереве (для detail-панели и контекстных операций).
    func find(_ target: URL) -> VaultNode? {
        if url.standardizedFileURL == target.standardizedFileURL { return self }
        guard let children else { return nil }
        for child in children {
            if let found = child.find(target) { return found }
        }
        return nil
    }

    /// Все папки поддерева (включая себя, если папка) — для меню «Переместить в…».
    var allFolders: [VaultNode] {
        guard isDirectory else { return [] }
        var result = [self]
        for child in children ?? [] {
            result.append(contentsOf: child.allFolders)
        }
        return result
    }
}

extension VaultNode {
    /// SF-символ узла — общий для дерева, breadcrumb и списка папки (задача 42).
    var systemImage: String {
        Self.systemImage(isDirectory: isDirectory, fileExtension: url.pathExtension)
    }

    /// Иконка по типу: папка или файл по расширению (пока различаем только
    /// markdown и аудио). Статическая версия — для PathSegment, у которого
    /// узла дерева под рукой нет.
    static func systemImage(isDirectory: Bool, fileExtension: String) -> String {
        if isDirectory { return "folder" }
        switch fileExtension.lowercased() {
        case "md": return "doc.text"
        case "m4a", "mp3", "wav": return "waveform"
        default: return "doc"
        }
    }
}

/// Построение дерева vault с диска.
enum VaultTree {
    /// Строит дерево от корня. `showsDotItems: false` скрывает всё, что
    /// начинается с точки (`.obsidian`, `.git`, `.trash`, `.DS_Store`) —
    /// служебные данные Obsidian/git не должны выглядеть как заметки.
    static func build(at root: URL, showsDotItems: Bool = false) throws -> VaultNode {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw VaultError.notADirectory(root.lastPathComponent)
        }
        return VaultNode(
            url: root.standardizedFileURL,
            name: root.lastPathComponent,
            isDirectory: true,
            children: try buildChildren(of: root, showsDotItems: showsDotItems)
        )
    }

    /// Рекурсивный обход папки. Символические ссылки не разыменовываем
    /// (isDirectoryKey у симлинка — false), чтобы не зациклиться.
    private static func buildChildren(of folder: URL, showsDotItems: Bool) throws -> [VaultNode] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showsDotItems ? [] : [.skipsHiddenFiles]
        )

        var nodes: [VaultNode] = []
        for url in contents {
            let name = url.lastPathComponent
            // skipsHiddenFiles покрывает не всё (например, папку с выставленным
            // флагом hidden показывать надо, а dot-имена — нет), поэтому
            // фильтруем по имени явно.
            if !showsDotItems && name.hasPrefix(".") { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            nodes.append(VaultNode(
                url: url.standardizedFileURL,
                name: name,
                isDirectory: isDirectory,
                children: isDirectory ? try buildChildren(of: url, showsDotItems: showsDotItems) : nil
            ))
        }
        return sorted(nodes)
    }

    /// Сортировка «папки сначала», внутри группы — как в Finder
    /// (localizedStandardCompare: кириллица и числа сортируются по-человечески).
    static func sorted(_ nodes: [VaultNode]) -> [VaultNode] {
        nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// Стабильный идентификатор vault по его пути. Используется как имя папки
/// производных данных: `~/Library/Application Support/SecondBrain/<vault-id>/`.
enum VaultID {
    /// SHA-256 стандартизованного пути, первые 16 hex-символов: детерминирован,
    /// без спецсимволов/кириллицы — безопасен как имя папки и ключ UserDefaults.
    static func make(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
}
