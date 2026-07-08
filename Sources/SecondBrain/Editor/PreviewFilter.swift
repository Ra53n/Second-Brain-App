// PreviewFilter.swift — подготовка текста к рендеру в «Превью» (MarkdownUI).
//
// MarkdownUI — обычный CommonMark/GFM-парсер (cmark-gfm), он не знает
// Obsidian-расширений (`^id`, `%% %%`, `==выделение==`) — без предобработки они
// вылезли бы как нечитаемый сырой текст (это и было исходной жалобой). Reading
// View самого Obsidian тоже никогда не показывает `%% %%` и `^id` читателю (там
// нет курсора, скрывать/показывать по позиции курсора — не для чего) — здесь то
// же самое: убираем целиком, безусловно.
//
// Порядок важен: сначала комментарии, потом блок-ссылки, потом выделение —
// иначе `^id`/`==...==`, случайно оказавшиеся внутри спрятанного JSON, тоже
// попали бы под замену до того, как весь блок исчезнет.
//
// `==выделение==` заменяется на `**жирный**` — cmark-gfm не поддерживает `==`
// нативно, а писать свой inline-рендер ради одного маркера непропорционально
// объёму; это честная задокументированная аппроксимация ТОЛЬКО для превью — в
// самом редакторе `MarkdownHighlighter.Kind.highlight` даёт настоящую жёлтую
// заливку (см. MarkdownEditorView.swift).
//
// Двойной пробел, который может остаться на месте вырезанного инлайн-блока —
// не баг: обычный markdown-рендер (как и HTML) схлопывает подряд идущие
// пробелы сам, визуально это незаметно.

import Foundation

enum PreviewFilter {

    static func apply(_ text: String) -> String {
        var result = stripCommentBlocks(text)
        result = stripBlockReferences(result)
        result = replaceHighlights(result)
        return result
    }

    private static func stripCommentBlocks(_ text: String) -> String {
        remove(CommentBlockParser.parse(text).map(\.range), from: text)
    }

    private static func stripBlockReferences(_ text: String) -> String {
        let ns = text as NSString
        // Вместе с токеном убираем один пробел перед «^», чтобы строка не
        // заканчивалась висячим пробелом («Пункт ^abc» → «Пункт», не «Пункт »).
        let ranges = BlockReferenceParser.parse(text).map { ref -> NSRange in
            var start = ref.range.location
            if start > 0, ns.character(at: start - 1) == 0x20 {
                start -= 1
            }
            return NSRange(location: start, length: NSMaxRange(ref.range) - start)
        }
        return remove(ranges, from: text)
    }

    private static let highlightRegex = try! NSRegularExpression(pattern: "==([^=\\n]+)==")

    private static func replaceHighlights(_ text: String) -> String {
        let full = NSRange(location: 0, length: (text as NSString).length)
        return highlightRegex.stringByReplacingMatches(in: text, options: [], range: full, withTemplate: "**$1**")
    }

    /// Вырезает набор (несвязных, отсортированных или нет) диапазонов из текста.
    private static func remove(_ ranges: [NSRange], from text: String) -> String {
        guard !ranges.isEmpty else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.location >= cursor {
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            cursor = NSMaxRange(range)
        }
        result += ns.substring(from: cursor)
        return result
    }
}
