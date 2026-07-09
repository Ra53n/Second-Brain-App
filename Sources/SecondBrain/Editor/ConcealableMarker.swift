// ConcealableMarker.swift — единая модель «скрываемых» фрагментов разметки.
//
// Live Preview (как в Obsidian): маркеры разметки (#, **, ==, `, [[/]], >, -/1.,
// ``` fences, %% …) НЕВИДИМЫ (глифы нуллифицируются, см. ConcealingLayoutDelegate),
// пока курсор редактирования не встанет на строку/внутрь блока; тогда
// проявляются. Содержимое (сам жирный текст, текст заголовка, код и т.п.)
// стилизуется ВСЕГДА — этим занимается Coordinator.applyMarkdownHighlighterMatches/
// applyWikilinks независимо от сокрытия; здесь — только маркеры.
//
// Один общий тип вместо N однотипных веток: конкретика («что вообще является
// маркером») живёт в фабриках ниже, само сокрытие — один общий механизм.
//
// revealStyle различает «как маркер выглядит, когда ПОКАЗАН»: plain — приглушён
// цветом; codeBlock — моноширинный с фоном код-блока (для %% и ``` fences).

import Foundation

/// Визуальный стиль ПОКАЗАННОГО маркера.
enum ConcealableRevealStyle: Equatable {
    /// Приглушённый цвет — #, **, ==, `, [[ ]], >, -/1.
    case plain
    /// Моноширинный + приглушённый фон код-блока — %% %% и ``` fences.
    case codeBlock
}

/// Один скрываемый маркер: один или несколько под-диапазонов символов разметки,
/// которые невидимы, пока курсор не пересекает revealTrigger.
struct ConcealableMarker: Equatable {
    /// Диапазон(ы) самих символов разметки — БЕЗ содержимого между ними.
    let hideRanges: [NSRange]
    /// Диапазон, пересечение курсора с которым показывает маркер: для
    /// однострочных конструкций — вся строка; для блочных (code fence, %% %%)
    /// — весь блок целиком (оба ограничителя раскрываются вместе).
    let revealTrigger: NSRange
    let revealStyle: ConcealableRevealStyle

    // MARK: - Фабрики

    /// Для одного BlockReference (см. BlockReferenceParser.swift).
    static func forBlockReference(_ ref: BlockReference) -> ConcealableMarker {
        ConcealableMarker(hideRanges: [ref.range], revealTrigger: ref.lineRange, revealStyle: .plain)
    }

    /// Один на CommentBlock (см. CommentBlockParser.swift) — маркер = блок целиком.
    static func forCommentBlock(_ block: CommentBlock) -> ConcealableMarker {
        ConcealableMarker(hideRanges: [block.range], revealTrigger: block.range, revealStyle: .codeBlock)
    }

    /// Из Wikilink.concealShape — префикс+суффикс прячутся, alias/target виден.
    static func forWikilink(_ link: Wikilink) -> ConcealableMarker {
        ConcealableMarker(
            hideRanges: [link.concealShape.hidePrefix, link.concealShape.hideSuffix],
            revealTrigger: link.range,
            revealStyle: .plain
        )
    }

    /// Из MarkdownHighlighter.Match: heading/bold/highlight/inlineCode/blockquote
    /// — однострочные, revealTrigger = строка начала match; codeBlock — оба
    /// ограждения ``` считаются построчно от match.range (без regex-группы),
    /// revealTrigger = блок целиком (как %% %%). Пусто — Match без маркеров.
    static func forHighlighterMatch(_ match: MarkdownHighlighter.Match, in ns: NSString) -> [ConcealableMarker] {
        switch match.kind {
        case .codeBlock:
            let openFence = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            let closeFenceStart = max(match.range.location, NSMaxRange(match.range) - 1)
            let closeFence = ns.lineRange(for: NSRange(location: closeFenceStart, length: 0))
            return [ConcealableMarker(
                hideRanges: [openFence, closeFence],
                revealTrigger: match.range,
                revealStyle: .codeBlock
            )]
        default:
            guard !match.markerRanges.isEmpty else { return [] }
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            return [ConcealableMarker(
                hideRanges: match.markerRanges,
                revealTrigger: lineRange,
                revealStyle: .plain
            )]
        }
    }

    // Отступ+маркер списка («  - »/«1. ») — прячутся одним диапазоном; сам
    // отступ безопасно скрывать, т.к. визуальный левый край держит
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
            return ConcealableMarker(hideRanges: [match.range], revealTrigger: lineRange, revealStyle: .plain)
        }
    }
}
