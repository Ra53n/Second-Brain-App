// ChecklistParser.swift — задачи `- [ ]`/`- [x]` в тексте заметки: разбор + переключение.
//
// GFM-чеклисты (тот же синтаксис понимает Obsidian): маркер списка («-», «*», «+»)
// + пробел + «[ ]»/«[x]»/«[X]» + пробел + текст пункта.
//
// Полноценный WYSIWYG (замена «[ ]» на настоящий виджет-чекбокс прямо в
// редакторе, как Live Preview в Obsidian) потребовал бы отдельного слоя
// декораций поверх NSTextKit — это большая система вне объёма правки.
// Вместо неё: 1) маркер и зачёркнутый текст выполненных пунктов подсвечиваются
// (MarkdownEditorView.Coordinator.highlight), 2) клик по «[ ]»/«[x]» переключает
// состояние ПРЯМО В ИСХОДНОМ ТЕКСТЕ (MarkdownTextView.mouseDown) — файл остаётся
// обычным markdown, совместимым с Obsidian, никаких скрытых символов не добавляется.

import Foundation

/// Один пункт чеклиста в тексте: где стоит маркер и где текст пункта.
struct ChecklistItem: Equatable {
    /// Диапазон «[ ]»/«[x]» целиком (со скобками) — цель клика для toggle.
    let markerRange: NSRange
    /// Диапазон текста пункта после маркера — зачёркивается, если выполнен.
    let contentRange: NSRange
    let isChecked: Bool
}

enum ChecklistParser {

    // Разрешаем "-", "*", "+" как в GFM/Obsidian; любой отступ (вложенные списки).
    private static let regex = try! NSRegularExpression(
        pattern: "^\\s*[-*+]\\s(\\[[ xX]\\])(.*)$", options: [.anchorsMatchLines]
    )

    /// Все пункты чеклиста в тексте, в порядке появления.
    static func parse(_ text: String) -> [ChecklistItem] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: full).map { match in
            let markerRange = match.range(at: 1)
            let isChecked = ns.substring(with: markerRange).lowercased() == "[x]"
            return ChecklistItem(markerRange: markerRange, contentRange: match.range(at: 2), isChecked: isChecked)
        }
    }

    /// Токен маркера после переключения (checked → "[ ]", unchecked → "[x]").
    /// Регистр не сохраняется: Obsidian при клике всегда пишет строчный «x».
    static func toggledMarker(currentlyChecked: Bool) -> String {
        currentlyChecked ? "[ ]" : "[x]"
    }
}
