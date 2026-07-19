// MeetingFolderPicker.swift — модель меню выбора папки для заметки встречи
// (задача 43). Чистая логика без SwiftUI: пункты меню, предвыбор, строка
// «ИИ предлагает», состояние пикера в настройках, подпись чипа статус-строки.
//
// View (диалог оформления, вкладка настроек «Встречи», чип) только рисуют
// то, что отдали эти функции, — вся решающая логика тестируется юнитами.
// Пункты меню — полные относительные пути (как в «Переместить в…» vault),
// порядок pre-order из VaultNode.allFolders читается как иерархия.

import Foundation

/// Строка меню папок: относительный путь + глубина вложенности (для отступа).
struct FolderMenuItem: Identifiable, Equatable {
    let path: String
    let depth: Int

    var id: String { path }

    init(path: String) {
        self.path = path
        self.depth = max(0, path.components(separatedBy: "/").count - 1)
    }
}

enum MeetingFolderPicker {

    /// Нормализация пути папки — как в MeetingNoteWriter.resolveFolder:
    /// пробелы/переводы строк и «/» по краям отбрасываются.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    /// Пункты меню: папки vault в исходном порядке (pre-order) + extras
    /// (дефолт пользователя, предложение ИИ, текущий выбор), которых нет
    /// в списке, — в конец. Пустые и повторные значения отбрасываются.
    static func menuItems(vaultFolders: [String], extras: [String]) -> [FolderMenuItem] {
        var seen = Set<String>()
        var items: [FolderMenuItem] = []
        for path in vaultFolders.map(normalize) where !path.isEmpty && seen.insert(path).inserted {
            items.append(FolderMenuItem(path: path))
        }
        for path in extras.map(normalize) where !path.isEmpty && seen.insert(path).inserted {
            items.append(FolderMenuItem(path: path))
        }
        return items
    }

    /// Предвыбор папки в диалоге оформления. Приоритет: подтверждённая ранее
    /// пользователем > папка по умолчанию из настроек > предложение ИИ >
    /// штатная Meetings/YYYY-MM. Пустые/пробельные значения пропускаются.
    static func preselected(confirmed: String?,
                            defaultFolder: String,
                            suggested: String,
                            date: Date) -> String {
        for candidate in [confirmed ?? "", defaultFolder, suggested] {
            let normalized = normalize(candidate)
            if !normalized.isEmpty { return normalized }
        }
        return MeetingNoteWriter.defaultFolder(for: date)
    }

    /// Предложение ИИ для отдельной строки «ИИ предлагает: X»; nil — если
    /// предложения нет или оно уже совпадает с текущим выбором (строка
    /// исчезает после «Применить»).
    static func aiSuggestion(suggested: String, currentSelection: String) -> String? {
        let normalized = normalize(suggested)
        guard !normalized.isEmpty, normalized != normalize(currentSelection) else { return nil }
        return normalized
    }

    /// Состояние пикера в Settings → «Встречи»: пусто — штатная папка
    /// (path == ""); значение из списка — обычный пункт; значение вне списка
    /// (вписано руками или папка удалена из vault) — custom-режим.
    static func settingsSelection(stored: String, available: [String])
        -> (path: String, isCustom: Bool) {
        let normalized = normalize(stored)
        if normalized.isEmpty { return ("", false) }
        let known = Set(available.map(normalize))
        return (normalized, !known.contains(normalized))
    }

    /// Подпись чипа статус-строки раздела «Встречи»: показывает, куда по
    /// умолчанию лягут заметки (пустая настройка — штатная папка месяца).
    static func chipTitle(defaultFolder: String, date: Date) -> String {
        let normalized = normalize(defaultFolder)
        let folder = normalized.isEmpty ? MeetingNoteWriter.defaultFolder(for: date) : normalized
        return "Папка: \(folder)"
    }
}
