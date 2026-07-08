// BlockReferenceParser.swift — блок-ссылки Obsidian `^id` в конце строки.
//
// Синтаксис: `^` сразу перед концом строки (без хвостовой пунктуации), которому
// ОБЯЗАТЕЛЬНО предшествует пробел — так `[[Заметка#^id]]` может сослаться на
// конкретный абзац/пункт. Правило «последний токен строки» отличает настоящую
// ссылку от случайного `^` в тексте: `решить x^2 через степень` — НЕ ссылка
// (после `^2` идёт ещё текст), а `Пункт списка ^abc123` — ссылка.
//
// Сами по себе ссылки некрасивы для чтения (случайный набор символов) — редактор
// приглушает/сворачивает их визуально, пока курсор не на этой строке (см.
// MarkdownEditorView.Coordinator.applyConcealables); здесь — только разбор.

import Foundation

/// Одна блок-ссылка в тексте.
struct BlockReference: Equatable {
    /// Диапазон самого токена `^id` (без предшествующего пробела).
    let range: NSRange
    /// Диапазон всей строки, на которой стоит ссылка — по нему проверяется,
    /// «курсор сейчас на этой строке» (сворачивание/разворачивание).
    let lineRange: NSRange
    /// Идентификатор без `^`.
    let id: String
}

enum BlockReferenceParser {

    // Пробел перед «^» обязателен (lookbehind); id — буквы/цифры/дефис;
    // после — только пробелы/табы до конца строки (последний токен строки).
    private static let regex = try! NSRegularExpression(
        pattern: "(?<=[ \\t])\\^([A-Za-z0-9-]+)[ \\t]*$",
        options: [.anchorsMatchLines]
    )

    /// Все блок-ссылки текста (вне код-блоков), в порядке появления.
    static func parse(_ text: String) -> [BlockReference] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let excluded = CodeRegionDetector.excludedRanges(in: text)

        var result: [BlockReference] = []
        for match in regex.matches(in: text, range: full) {
            let idRange = match.range(at: 1)
            // Токен — от «^» до конца id (без хвостовых пробелов).
            let caretRange = NSRange(location: match.range.location, length: NSMaxRange(idRange) - match.range.location)
            if CodeRegionDetector.isExcluded(caretRange, from: excluded) { continue }

            let lineRange = ns.lineRange(for: NSRange(location: caretRange.location, length: 0))
            result.append(BlockReference(
                range: caretRange,
                lineRange: lineRange,
                id: ns.substring(with: idRange)
            ))
        }
        return result
    }
}
