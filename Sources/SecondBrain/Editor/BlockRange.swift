// BlockRange.swift — расширение диапазона правки до объемлющего логического блока.
//
// Ядро инкрементальной подсветки (MarkdownEditorView.highlightIncrementally):
// когда пользователь что-то напечатал, нам нужно перекрасить/перепарсить НЕ весь
// документ, а только «грязный» блок вокруг правки. Блок здесь — как в
// ParagraphStyling: максимальный набор непустых строк между пустыми строками.
// В отличие от ParagraphStyling.paragraphRanges (O(документа), собирает все блоки),
// enclosingBlock работает локально — O(размера блока) — расширяясь вверх/вниз от
// строки правки до ближайших пустых строк.
//
// Пустая строка как единственная граница — сознательно консервативно: лишняя
// пара захваченных строк безопасна (перепарс блока всё равно корректен, все
// инлайн-конструкции однострочные), а многоблочные код-фенсы ``` и %%-комментарии
// обрабатывает отдельный fallback (MarkdownEditorView.needsFullRehighlight), а не
// расширение блока. Все смещения — UTF-16 (NSString.lineRange), безопасно для
// кириллицы/эмодзи.

import Foundation

enum BlockRange {

    /// Диапазон логического блока (между пустыми строками), охватывающего edited.
    /// Расширяет edited вверх до строки после ближайшей пустой строки (или начала
    /// документа) и вниз до строки перед ближайшей пустой строкой (или конца).
    /// Клампится в [0, length]. Пустой документ → NSRange(0, 0).
    static func enclosingBlock(of edited: NSRange, in ns: NSString) -> NSRange {
        let length = ns.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        // Пробы клампим в [0, length-1] — lineRange требует позицию внутри строки;
        // правка в самом конце (location == length) относится к последней строке.
        let startProbe = min(max(edited.location, 0), length - 1)
        let endProbe = min(max(NSMaxRange(edited), edited.location), length - 1)

        var blockStart = ns.lineRange(for: NSRange(location: startProbe, length: 0)).location
        var blockEnd = NSMaxRange(ns.lineRange(for: NSRange(location: endProbe, length: 0)))

        // Вверх: пока предыдущая строка непустая — она часть того же блока.
        while blockStart > 0 {
            let prevLine = ns.lineRange(for: NSRange(location: blockStart - 1, length: 0))
            if isBlank(ns, prevLine) { break }
            blockStart = prevLine.location
        }
        // Вниз: пока следующая строка непустая.
        while blockEnd < length {
            let nextLine = ns.lineRange(for: NSRange(location: blockEnd, length: 0))
            if isBlank(ns, nextLine) { break }
            blockEnd = NSMaxRange(nextLine)
        }

        return NSRange(location: blockStart, length: blockEnd - blockStart)
    }

    /// Сдвиг диапазона на offset — маппинг результатов парсинга подстроки блока
    /// обратно в абсолютные координаты документа. offset 0 → без изменений.
    static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        offset == 0 ? range : NSRange(location: range.location + offset, length: range.length)
    }

    /// Строка состоит только из пробелов/переводов строки (разделитель блоков).
    private static func isBlank(_ ns: NSString, _ line: NSRange) -> Bool {
        ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
