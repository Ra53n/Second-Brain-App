// ConcealableMarker.swift — единая модель «сворачиваемых» фрагментов разметки.
//
// Live Preview (как в Obsidian): маркеры разметки (#, **, ==, `, [[/]], >, -/1.,
// ``` fences) свёрнуты — мелкий приглушённый шрифт, — пока курсор редактирования
// не встанет на строку/внутрь блока; тогда разворачиваются до обычного размера
// (для %%/``` — до моноширинного с фоном код-блока). Содержимое (сам жирный
// текст, текст заголовка, код и т.п.) стилизуется ВСЕГДА — этим занимается
// MarkdownEditorView.Coordinator.applyMarkdownHighlighterMatches/applyWikilinks
// независимо от состояния сворачивания; здесь — только маркеры.
//
// Один общий тип вместо N однотипных веток в Coordinator.styleConcealables —
// конкретика («что вообще является маркером») живёт в фабриках ниже, само
// сворачивание — один generic-цикл.

import Foundation

/// Визуальный стиль РАЗВЁРНУТОГО маркера.
enum ConcealableRevealStyle: Equatable {
    /// Обычный шрифт + secondaryLabelColor — #, **, ==, `, [[ ]], >, -/1.
    case plain
    /// Моноширинный + приглушённый фон код-блока — %% %% и ``` fences.
    case codeBlock
}

/// Один сворачиваемый маркер: один или несколько под-диапазонов символов
/// разметки, которые схлопываются в мелкий шрифт, пока курсор не пересекает
/// revealTrigger.
struct ConcealableMarker: Equatable {
    /// Диапазон(ы) самих символов разметки — БЕЗ содержимого между ними.
    let hideRanges: [NSRange]
    /// Диапазон, пересечение курсора с которым разворачивает маркер: для
    /// однострочных конструкций — вся строка; для блочных (code fence, %% %%)
    /// — весь блок целиком (оба ограничителя раскрываются вместе).
    let revealTrigger: NSRange
    let revealStyle: ConcealableRevealStyle
    /// Размер шрифта в свёрнутом состоянии — 5pt для однострочных маркеров,
    /// 4pt для блочных (схлопывает и line-height огромных скрытых блоков).
    let concealedFontSize: CGFloat

    // MARK: - Фабрики

    /// Список для одного BlockReference (см. BlockReferenceParser.swift).
    static func forBlockReference(_ ref: BlockReference) -> ConcealableMarker {
        ConcealableMarker(hideRanges: [ref.range], revealTrigger: ref.lineRange, revealStyle: .plain, concealedFontSize: 5)
    }

    /// Один на CommentBlock (см. CommentBlockParser.swift) — маркер = блок целиком.
    static func forCommentBlock(_ block: CommentBlock) -> ConcealableMarker {
        ConcealableMarker(hideRanges: [block.range], revealTrigger: block.range, revealStyle: .codeBlock, concealedFontSize: 4)
    }

    /// Из Wikilink.concealShape — префикс+суффикс прячутся, alias/target виден.
    static func forWikilink(_ link: Wikilink) -> ConcealableMarker {
        ConcealableMarker(
            hideRanges: [link.concealShape.hidePrefix, link.concealShape.hideSuffix],
            revealTrigger: link.range,
            revealStyle: .plain,
            concealedFontSize: 5
        )
    }

    /// Из MarkdownHighlighter.Match: heading/bold/highlight/inlineCode/blockquote
    /// — однострочные, revealTrigger = строка начала match; codeBlock — оба
    /// ограждения ``` считаются построчно от match.range (без regex-группы),
    /// revealTrigger = блок целиком (как %% %%). nil — Match без маркеров
    /// (сюда не должно попадать, но на всякий случай не роняем highlight()).
    static func forHighlighterMatch(_ match: MarkdownHighlighter.Match, in ns: NSString) -> [ConcealableMarker] {
        switch match.kind {
        case .codeBlock:
            let openFence = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            let closeFenceStart = max(match.range.location, NSMaxRange(match.range) - 1)
            let closeFence = ns.lineRange(for: NSRange(location: closeFenceStart, length: 0))
            return [ConcealableMarker(
                hideRanges: [openFence, closeFence],
                revealTrigger: match.range,
                revealStyle: .codeBlock,
                concealedFontSize: 4
            )]
        default:
            guard !match.markerRanges.isEmpty else { return [] }
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            return [ConcealableMarker(
                hideRanges: match.markerRanges,
                revealTrigger: lineRange,
                revealStyle: .plain,
                concealedFontSize: 5
            )]
        }
    }

    // Отступ+маркер списка («  - »/«1. ») — прячутся одним диапазоном; сам
    // отступ безопасно сворачивать, т.к. визуальный левый край держит
    // ParagraphStyling.headIndent (атрибут абзаца), а не сырые пробелы исходника.
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: "^\\s*(?:[-*+]|\\d+\\.)[ \\t]", options: [.anchorsMatchLines]
    )

    /// Один маркер на каждую строку-пункт списка (вне код-блоков).
    static func forListMarkers(in text: String) -> [ConcealableMarker] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let excluded = CodeRegionDetector.excludedRanges(in: text)

        return listMarkerRegex.matches(in: text, range: full).compactMap { match in
            guard !CodeRegionDetector.isExcluded(match.range, from: excluded) else { return nil }
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            return ConcealableMarker(hideRanges: [match.range], revealTrigger: lineRange, revealStyle: .plain, concealedFontSize: 5)
        }
    }
}
