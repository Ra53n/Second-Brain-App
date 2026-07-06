// VaultFileOperations.swift — CRUD-операции над файлами vault + VaultError.
//
// Инвариант №1 (ARCHITECTURE.md): vault — источник истины, приложение не имеет
// права терять или молча перезаписывать пользовательские файлы. Отсюда правила
// этого файла:
//  - создание — только с уникальным именем («Без названия 2.md», не перезапись);
//  - rename/move — падают с ошибкой, если цель уже существует;
//  - удаление — ТОЛЬКО в Корзину (FileManager.trashItem), не безвозвратно.
//
// Всё — чистые статические функции без состояния: тестируются на temp-директории.

import Foundation

/// Ошибки операций с vault. Сообщения готовы к показу в UI (LocalizedError).
enum VaultError: LocalizedError, Equatable {
    case notADirectory(String)
    case alreadyExists(String)
    case invalidName(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let name):
            return "«\(name)» — не папка."
        case .alreadyExists(let name):
            return "«\(name)» уже существует."
        case .invalidName(let name):
            return "Недопустимое имя: «\(name)»."
        case .operationFailed(let reason):
            return "Операция не выполнена: \(reason)"
        }
    }
}

/// CRUD над файлами и папками vault. Все операции возвращают итоговый URL —
/// вызывающий (VaultManager) перестраивает дерево и обновляет selection.
enum VaultFileOperations {

    /// Создаёт пустую заметку `<name>.md` в папке, подбирая уникальное имя
    /// («Без названия.md» → «Без названия 2.md» → …). Никогда не перезаписывает.
    @discardableResult
    static func createNote(in folder: URL, named name: String = "Без названия") throws -> URL {
        let url = try uniqueURL(in: folder, baseName: name, ext: "md")
        // createFile не бросает — проверяем результат сами, чтобы донести ошибку.
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw VaultError.operationFailed("не удалось создать «\(url.lastPathComponent)»")
        }
        return url
    }

    /// Создаёт папку с уникальным именем («Новая папка», «Новая папка 2», …).
    @discardableResult
    static func createFolder(in folder: URL, named name: String = "Новая папка") throws -> URL {
        let url = try uniqueURL(in: folder, baseName: name, ext: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Создаёт произвольный пустой файл (имя с расширением, как ввёл пользователь).
    @discardableResult
    static func createFile(in folder: URL, named fileName: String) throws -> URL {
        try validate(name: fileName)
        let url = folder.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.alreadyExists(fileName)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw VaultError.operationFailed("не удалось создать «\(fileName)»")
        }
        return url
    }

    /// Переименовывает файл/папку. Цель существует → ошибка (не перезаписываем).
    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        try validate(name: newName)
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard target.standardizedFileURL != url.standardizedFileURL else { return url }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw VaultError.alreadyExists(newName)
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Перемещает файл/папку в другую папку. Занятое имя в цели → ошибка.
    @discardableResult
    static func move(_ url: URL, into folder: URL) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw VaultError.notADirectory(folder.lastPathComponent)
        }
        let target = folder.appendingPathComponent(url.lastPathComponent)
        guard target.standardizedFileURL != url.standardizedFileURL else { return url }
        // Папку внутрь самой себя — отказ (moveItem зациклил бы структуру).
        guard !folder.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") else {
            throw VaultError.operationFailed("нельзя переместить папку внутрь самой себя")
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw VaultError.alreadyExists(url.lastPathComponent)
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Удаляет В КОРЗИНУ. Безвозвратного удаления в приложении нет вообще —
    /// это цена инварианта «не терять пользовательские файлы».
    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - Внутреннее

    /// Подбирает свободный URL: `base.ext`, `base 2.ext`, `base 3.ext`, …
    private static func uniqueURL(in folder: URL, baseName: String, ext: String?) throws -> URL {
        try validate(name: baseName)
        let fm = FileManager.default
        for attempt in 1...10_000 {
            let name = attempt == 1 ? baseName : "\(baseName) \(attempt)"
            let candidate = ext.map { folder.appendingPathComponent(name).appendingPathExtension($0) }
                ?? folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        throw VaultError.operationFailed("не нашлось свободного имени для «\(baseName)»")
    }

    /// Имя не пустое, без «/» и не начинается с точки (dot-файлы скрыты в дереве —
    /// пользователь создал бы невидимый для себя файл).
    private static func validate(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else {
            throw VaultError.invalidName(name)
        }
    }
}
