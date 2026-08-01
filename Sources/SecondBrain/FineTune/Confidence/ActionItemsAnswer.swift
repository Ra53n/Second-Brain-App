// ActionItemsAnswer.swift — типы и строгий парсер ответа модели на извлечение поручений
// (задача 85). Порт `parse()`/`normalize()` из finetune/actionitem_checks.py.

import Foundation

struct ActionItem: Equatable, Codable {
    var assignee: String?
    var task: String
    var due: String?
}

enum ActionItemsParser {
    private static let itemKeys: Set<String> = ["assignee", "task", "due"]

    /// Строгий разбор: объект с единственным ключом `action_items`, список элементов
    /// ровно по схеме `{assignee, task, due}`. Отклонение от `finetune/actionitem_checks.py`:
    /// python-`parse()` не проверяет схему элементов (это отдельная проверка «схема
    /// элементов» в `run_checks()`) и не режет обёртку ```; здесь обе проверки объединены,
    /// потому что `ActionItem` — типизированная структура и половинчатого результата не
    /// бывает. Раздельная семантика для 9-проверочного порта — `ConfidenceChecks`,
    /// использующий `parseTopLevel`/`validateItems` напрямую.
    static func parse(_ raw: String) -> [ActionItem]? {
        guard let rawItems = parseTopLevel(raw) else { return nil }
        let (valid, badCount) = validateItems(rawItems)
        guard badCount == 0 else { return nil }
        return valid
    }

    /// Только структурная форма — зеркало python `parse()` дословно: `{action_items: [...]}`
    /// без проверки содержимого элементов.
    static func parseTopLevel(_ raw: String) -> [Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let dict = value as? [String: Any], Set(dict.keys) == ["action_items"] else { return nil }
        return dict["action_items"] as? [Any]
    }

    /// Схема элемента как в python (`set(item) == {"assignee","task","due"}` плюс типы
    /// значений) — отдельно от `parseTopLevel`, чтобы «схема элементов» была своей проверкой.
    static func validateItems(_ raw: [Any]) -> (valid: [ActionItem], badCount: Int) {
        var valid: [ActionItem] = []
        var badCount = 0
        for element in raw {
            if let item = decodeItem(element) {
                valid.append(item)
            } else {
                badCount += 1
            }
        }
        return (valid, badCount)
    }

    /// lowercase + схлопывание пробельных в один + trim — без замены «ё»→«е»
    /// (python `normalize()` её не делает: `str.lower()` кириллицу «ё» не трогает).
    static func normalize(_ text: String?) -> String {
        (text ?? "").lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func decodeItem(_ element: Any) -> ActionItem? {
        guard let dict = element as? [String: Any], Set(dict.keys) == itemKeys else { return nil }
        guard let task = dict["task"] as? String,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let assignee = nullableString(dict["assignee"]) else { return nil }
        guard let due = nullableString(dict["due"]) else { return nil }
        return ActionItem(assignee: assignee, task: task, due: due)
    }

    /// nil снаружи — значение не строка и не null (элемент невалиден); nil внутри —
    /// JSON `null`. `.some(none)` собирается явно — `Optional<String?>(nil)` схлопывает
    /// двойной optional в плоский `nil` (компилятор трактует литерал `nil` как внешний
    /// `ExpressibleByNilLiteral`, а не как обёртку значения).
    private static func nullableString(_ value: Any?) -> String?? {
        guard let value else { return nil }
        if value is NSNull {
            let none: String? = nil
            return .some(none)
        }
        if let string = value as? String { return .some(string) }
        return nil
    }
}
