// ConcealingLayoutDelegate.swift — настоящее сокрытие маркеров разметки в Live Preview.
//
// Скрытые диапазоны (#, **, ` , [[ ]], >, -/1., ``` , %% …) остаются в
// textView.string (файл не меняется), но НЕ рисуются и НЕ занимают места.
//
// Механика — ДЕТЕРМИНИРОВАННАЯ ГЕОМЕТРИЯ (иначе строки «съезжали» и не
// возвращались):
//  1) shouldGenerateGlyphs помечает скрытые символы .controlCharacter, а
//     shouldUseAction даёт им .zeroAdvancement — невидимы, нулевая ширина, но
//     глиф остаётся В СВОЕЙ строке. НЕ `.null`: ведущие null-глифы абзаца
//     (# заголовка, «- » списка) пришивались к предыдущему фрагменту, и
//     верстальщик терял paragraphSpacingBefore — высота строки менялась при
//     раскрытии, контент ниже прыгал на каждый клик.
//  2) hideRanges никогда не содержат \n (инвариант ConcealableMarker): слияние
//     строк ломало высоты. Полностью скрытые строки (фенсы ```, строки %%)
//     схлопывает shouldSetLineFragmentRect — высота фрагмента задаётся явно.
//  3) Смена раскрытого набора — полный пересчёт раскладки + якорение строки
//     курсора (Coordinator.restyleConcealedRanges): ошибке высот негде копиться.
//
// Диапазоны отсортированы и слиты, проверка вхождения — бинарным поиском.
// concealedRanges/fullyConcealedLines обновляет Coordinator (primeConcealment).

import AppKit

final class ConcealingLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    /// Скрытые диапазоны символов — ОТСОРТИРОВАНЫ по location и СЛИТЫ (без
    /// пересечений). Инвариант держит ConcealableMarker/Coordinator через
    /// mergeRanges; бинарный поиск в isConcealed на это опирается.
    var concealedRanges: [NSRange] = []

    /// Строки, чей контент скрыт ЦЕЛИКОМ (строки-фенсы ```, строки %%-блоков) —
    /// их фрагментам даётся схлопнутая высота в shouldSetLineFragmentRect.
    /// Диапазоны — ПОЛНЫЕ lineRange (с \n), отсортированы, без пересечений.
    /// Почему так, а не нуллификация \n: слияние строк давало недетерминированные
    /// высоты (текст «съезжал» и не возвращался); здесь высота задаётся явно на
    /// каждом проходе раскладки — детерминированно. Ставит Coordinator.
    var fullyConcealedLines: [NSRange] = []

    /// Высота схлопнутой строки. Не 0 — нулевые фрагменты NSLayoutManager
    /// обрабатывает ненадёжно; 1pt глазу не виден.
    static let collapsedLineHeight: CGFloat = 1

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

    /// Строка (по индексу первого символа её фрагмента) полностью скрыта?
    /// Бинарный поиск по отсортированным неперекрывающимся lineRange.
    private func isFullyConcealedLine(containing characterIndex: Int) -> Bool {
        var low = 0
        var high = fullyConcealedLines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = fullyConcealedLines[mid]
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

    // MARK: - NSLayoutManagerDelegate

    /// Схлопывание полностью скрытых строк: официальный механизм фолдинга в
    /// TextKit 1 — управляем высотой фрагмента строки напрямую, детерминированно
    /// на каждом проходе раскладки (в отличие от эмерджентной высоты от
    /// нуллификации глифов).
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard !fullyConcealedLines.isEmpty else { return false }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard isFullyConcealedLine(containing: charRange.location) else { return false }
        lineFragmentRect.pointee.size.height = Self.collapsedLineHeight
        lineFragmentUsedRect.pointee.size.height = Self.collapsedLineHeight
        baselineOffset.pointee = 0
        return true
    }

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

        // Помечаем скрытые символы .controlCharacter (+ .zeroAdvancement в
        // shouldUseAction ниже) — невидимы, нулевая ширина, но, В ОТЛИЧИЕ от
        // .null, глиф остаётся в СВОЕЙ строке. С .null ведущие скрытые глифы
        // абзаца (# заголовка, «- » списка) пришивались к предыдущему фрагменту,
        // верстальщик терял paragraphSpacingBefore/интерлиньяж — строка меняла
        // высоту при раскрытии, контент ниже «съезжал» на каждый клик.
        var hasConcealed = false
        let newProperties = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
        defer { newProperties.deallocate() }
        for i in 0..<count {
            if isConcealed(characterIndexes[i]) {
                newProperties[i] = .controlCharacter
                hasConcealed = true
            } else {
                newProperties[i] = properties[i]
            }
        }
        guard hasConcealed else { return 0 }

        layoutManager.setGlyphs(glyphs, properties: newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }

    /// Действие для control-глифов: скрытые маркеры — нулевая ширина (невидимы,
    /// строку не покидают); настоящие control-символы (\n, \t) — их штатное действие.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        isConcealed(charIndex) ? .zeroAdvancement : action
    }
}
