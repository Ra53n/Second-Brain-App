// ConcealingLayoutDelegate.swift — настоящее сокрытие маркеров разметки в Live Preview.
//
// Делает глифы «скрытых» диапазонов (#, **, ` , [[ ]], >, -/1., ``` , %% …)
// нулевыми (`.null`): символы остаются в textView.string (файл не меняется),
// но НЕ рисуются и НЕ занимают места. Это в отличие от прежнего приёма с мелким
// шрифтом (4–5pt) — тот оставлял маркеры видимыми крошечным текстом, что и
// раздражало: «я не должен видеть форматирование».
//
// Как это работает: NSTextView в TextKit-1 (принудительно — обращением к
// layoutManager) на генерацию глифов зовёт shouldGenerateGlyphs; там символы,
// попадающие в concealedRanges, помечаются `.null`. Когда курсор заходит на
// строку/в блок, Coordinator убирает её диапазоны из concealedRanges и
// инвалидирует глифы — маркеры проявляются. Диапазоны отсортированы и слиты,
// проверка вхождения — бинарным поиском (документ большой, зовётся на каждый глиф).
//
// concealedRanges обновляет Coordinator (см. applyConcealables/restyleConcealedRanges).

import AppKit

final class ConcealingLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    /// Скрытые диапазоны символов — ОТСОРТИРОВАНЫ по location и СЛИТЫ (без
    /// пересечений). Инвариант держит ConcealableMarker/Coordinator через
    /// mergeRanges; бинарный поиск в isConcealed на это опирается.
    var concealedRanges: [NSRange] = []

    /// Символ скрыт? Бинарный поиск по отсортированным неперекрывающимся диапазонам.
    func isConcealed(_ characterIndex: Int) -> Bool {
        var low = 0
        var high = concealedRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = concealedRanges[mid]
            if characterIndex < range.location {
                high = mid - 1
            } else if characterIndex >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    /// Сортирует и сливает пересекающиеся/смежные диапазоны — предусловие
    /// бинарного поиска. Пустые (length 0) отбрасываются.
    static func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                let end = max(NSMaxRange(last), NSMaxRange(range))
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: - NSLayoutManagerDelegate

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !concealedRanges.isEmpty else { return 0 } // нет скрытого — стандартная генерация
        let count = glyphRange.length

        // Помечаем скрытые символы .null (невидимы, нулевая ширина); остальные —
        // как есть. Если в ране нет скрытых, не вмешиваемся (return 0).
        var hasConcealed = false
        let newProperties = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
        defer { newProperties.deallocate() }
        for i in 0..<count {
            if isConcealed(characterIndexes[i]) {
                newProperties[i] = .null
                hasConcealed = true
            } else {
                newProperties[i] = properties[i]
            }
        }
        guard hasConcealed else { return 0 }

        layoutManager.setGlyphs(glyphs, properties: newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }
}
