// CodeRegionDetector.swift — диапазоны код-блоков ``` и инлайн-кода `...` в тексте.
//
// Общий детектор для всех лёгких inline-парсеров заметки (wikilinks, чеклисты,
// блок-ссылки, %%-комментарии): код — не место для их синтаксиса, только текст
// внутри должен остаться как есть. Раньше этот регэксп-дубль жил в каждом
// парсере отдельно (MarkdownHighlighter, WikilinkParser) — вынесен сюда, чтобы
// у «что считается кодом» был один источник правды.

import Foundation

enum CodeRegionDetector {
    /// Код-блоки: от открывающего ``` на начале строки либо до закрывающего ``` на начале строки,
    /// либо до конца документа. Незакрытый блок считается открытым до конца — содержимое внутри
    /// защищено от интерпретации как разметка (wikilinks, чеклисты и т.п.), даже если пользователь
    /// забыл закрыть тройки. Это соответствует поведению VS Code и Obsidian: явно открытый код
    /// должен быть защищён.
    private static let codeBlockRegex = try! NSRegularExpression(
        pattern: "^```[\\s\\S]*?(?:^```|\\Z)", options: [.anchorsMatchLines]
    )
    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: "`[^`\\n]+`"
    )

    /// Диапазоны код-блоков и инлайн-кода в тексте (UTF-16), в произвольном порядке.
    static func excludedRanges(in text: String) -> [NSRange] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        return codeBlockRegex.matches(in: text, range: full).map(\.range)
            + inlineCodeRegex.matches(in: text, range: full).map(\.range)
    }

    /// true, если range пересекается хоть с одним код-регионом.
    static func isExcluded(_ range: NSRange, from excluded: [NSRange]) -> Bool {
        excluded.contains { NSIntersectionRange($0, range).length > 0 }
    }
}
