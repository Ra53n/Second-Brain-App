// MarkdownEditingCommands.swift — обсидиановские удобства редактирования: чистая
// логика (без AppKit), применяется в MarkdownTextView через shouldChangeText/
// didChangeText (чтобы попадало в undo, автосейв и инкрементальную подсветку).
//
// Здесь — ЧТО вставить/заменить; КАК (через textStorage) — в MarkdownTextView.
// Всё в UTF-16 (NSRange/NSString), как остальная разметка.

import Foundation

enum MarkdownEditingCommands {

    /// Результат авто-продолжения списка по Enter.
    struct NewlineResult: Equatable {
        /// Заменяемый диапазон: точка вставки (length 0) для продолжения, либо
        /// весь префикс строки — для очистки пустого пункта.
        let replaceRange: NSRange
        let replacement: String
        /// Куда поставить курсор после правки (абсолютная позиция).
        let cursor: Int
    }

    /// Результат ⌘B/⌘I (обернуть/снять маркер).
    struct WrapResult: Equatable {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    // Строка-пункт списка: отступ, маркер (-/*/+ или «N.»), пробелы, опц. чекбокс, текст.
    private static let listLineRegex = try! NSRegularExpression(
        pattern: "^([ \\t]*)([-*+]|\\d+\\.)([ \\t]+)(\\[[ xX]\\][ \\t]+)?(.*)$"
    )

    /// Что вставить при Enter: продолжить список (новый маркер, для «N.» — номер+1,
    /// для чеклиста — «[ ] »), либо — на пустом пункте — убрать маркер (выход из
    /// списка). nil — обычный перенос (не список / есть выделение).
    static func newlineInsertion(in text: NSString, selection: NSRange) -> NewlineResult? {
        guard selection.length == 0 else { return nil }

        let lineRange = text.lineRange(for: selection)
        // Строка без завершающего перевода строки — для корректного «$» и очистки.
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location {
            let c = text.character(at: contentEnd - 1)
            if c == 0x0A || c == 0x0D { contentEnd -= 1 } else { break }
        }
        let lineContent = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
        let lineStr = text.substring(with: lineContent)
        let lineNS = lineStr as NSString
        guard let m = listLineRegex.firstMatch(in: lineStr, range: NSRange(location: 0, length: lineNS.length)) else {
            return nil
        }

        let indent = lineNS.substring(with: m.range(at: 1))
        let markerTok = lineNS.substring(with: m.range(at: 2))
        let spacing = lineNS.substring(with: m.range(at: 3))
        let hasCheckbox = m.range(at: 4).location != NSNotFound
        let content = lineNS.substring(with: m.range(at: 5))

        // Пустой пункт (Enter на «- »/«- [ ] » без текста) → убрать маркер.
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return NewlineResult(replaceRange: lineContent, replacement: "", cursor: lineContent.location)
        }

        // Продолжить список.
        let nextMarker: String
        if markerTok.hasSuffix("."), let n = Int(markerTok.dropLast()) {
            nextMarker = "\(n + 1)."
        } else {
            nextMarker = markerTok
        }
        let checkbox = hasCheckbox ? "[ ] " : ""
        let prefix = "\n" + indent + nextMarker + spacing + checkbox
        let insertAt = selection.location
        return NewlineResult(
            replaceRange: NSRange(location: insertAt, length: 0),
            replacement: prefix,
            cursor: insertAt + (prefix as NSString).length
        )
    }

    /// ⌘B/⌘I: обернуть выделение в marker (** или *), снять — если уже обёрнуто
    /// (внутри выделения либо маркеры сразу вокруг него); без выделения — вставить
    /// пару и поставить курсор внутрь.
    static func wrapToggle(in text: NSString, selection: NSRange, marker: String) -> WrapResult {
        let mLen = (marker as NSString).length
        guard selection.length > 0 else {
            return WrapResult(range: selection, replacement: marker + marker, selection: NSRange(location: selection.location + mLen, length: 0))
        }
        let selected = text.substring(with: selection)
        let selectedNS = selected as NSString

        // Маркеры внутри выделения — снять.
        if selectedNS.length >= 2 * mLen, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = selectedNS.substring(with: NSRange(location: mLen, length: selectedNS.length - 2 * mLen))
            return WrapResult(range: selection, replacement: inner, selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        // Маркеры сразу вокруг выделения — снять внешние.
        if selection.location >= mLen, NSMaxRange(selection) + mLen <= text.length {
            let before = text.substring(with: NSRange(location: selection.location - mLen, length: mLen))
            let after = text.substring(with: NSRange(location: NSMaxRange(selection), length: mLen))
            if before == marker, after == marker {
                return WrapResult(
                    range: NSRange(location: selection.location - mLen, length: selection.length + 2 * mLen),
                    replacement: selected,
                    selection: NSRange(location: selection.location - mLen, length: selection.length)
                )
            }
        }
        // Иначе — обернуть.
        return WrapResult(
            range: selection,
            replacement: marker + selected + marker,
            selection: NSRange(location: selection.location + mLen, length: selection.length)
        )
    }

    /// Маркер для оборачивания выделения при вводе символа форматирования
    /// (`*`/`` ` ``/`_`). nil — символ не оборачивающий.
    static func wrapMarker(forTyped typed: String) -> String? {
        switch typed {
        case "*", "`", "_": return typed
        default: return nil
        }
    }
}
