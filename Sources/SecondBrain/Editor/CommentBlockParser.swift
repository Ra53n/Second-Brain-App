// CommentBlockParser.swift — скрытые Obsidian-комментарии `%% ... %%`.
//
// Однострочные (`%%текст%%`) и многострочные (открывающий `%%` один на строке,
// …, закрывающий `%%` один на строке — так плагин Excalidraw прячет сырой JSON
// рисунка). Не единый жадный регэксп на весь диапазон: на файле с сотнями строк
// base64 нежадный `[\s\S]*?` между двумя далёкими маркерами — риск на
// катастрофический бэктрекинг. Вместо этого находим ВСЕ вхождения «%%» и
// связываем их последовательно попарно (1–2, 3–4, …) — Obsidian не поддерживает
// вложенность `%% %%`, так что это не упрощение, а точное соответствие формату.
//
// Незакрытый «%%» (нечётный, последний) — блок тянется до конца документа:
// показывать сотни строк «хвоста» необработанным текстом хуже, чем спрятать
// всё до EOF (см. isTerminated=false — можно отличить в UI при желании).

import Foundation

/// Один скрытый блок-комментарий.
struct CommentBlock: Equatable {
    /// Диапазон целиком — от открывающего «%%» до закрывающего включительно
    /// (или до конца документа, если не закрыт).
    let range: NSRange
    let isTerminated: Bool
}

enum CommentBlockParser {

    private static let markerRegex = try! NSRegularExpression(pattern: "%%")

    /// Все комментарий-блоки текста (маркеры внутри код-блоков не считаются).
    static func parse(_ text: String) -> [CommentBlock] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let excludedCode = CodeRegionDetector.excludedRanges(in: text)

        let markers = markerRegex.matches(in: text, range: full)
            .map(\.range)
            .filter { !CodeRegionDetector.isExcluded($0, from: excludedCode) }

        var blocks: [CommentBlock] = []
        var index = 0
        while index < markers.count {
            let open = markers[index]
            if index + 1 < markers.count {
                let close = markers[index + 1]
                let range = NSRange(location: open.location, length: NSMaxRange(close) - open.location)
                blocks.append(CommentBlock(range: range, isTerminated: true))
                index += 2
            } else {
                // Непарный маркер — до конца документа.
                let range = NSRange(location: open.location, length: full.length - open.location)
                blocks.append(CommentBlock(range: range, isTerminated: false))
                index += 1
            }
        }
        return blocks
    }
}
