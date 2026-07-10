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
    /// ИНВАРИАНТ: hideRanges никогда не содержат символов перевода строки —
    /// нуллификация \n «сливала» строки, и TextKit 1 при частичной
    /// реинвалидации копил ошибку высот (текст съезжал и не возвращался).
    /// Полностью скрытые строки схлопывает по высоте ConcealingLayoutDelegate
    /// (shouldSetLineFragmentRect), а не слияние строк.
    let hideRanges: [NSRange]
    /// Диапазон, пересечение курсора с которым показывает маркер: для
    /// однострочных конструкций — вся строка; для блочных (code fence, %% %%)
    /// — весь блок целиком (оба ограничителя раскрываются вместе).
    let revealTrigger: NSRange
    let revealStyle: ConcealableRevealStyle

    /// Копия со всеми диапазонами (revealTrigger + все hideRanges), сдвинутыми на
    /// delta — для инкрементальной подсветки: маркеры ПОСЛЕ правки сдвигаются на
    /// изменение длины, маркеры блока парсятся локально и сдвигаются в абсолютные
    /// координаты (MarkdownEditorView.rebuiltConcealables / highlightIncrementally).
    func shifted(by delta: Int) -> ConcealableMarker {
        guard delta != 0 else { return self }
        return ConcealableMarker(
            hideRanges: hideRanges.map { NSRange(location: $0.location + delta, length: $0.length) },
            revealTrigger: NSRange(location: revealTrigger.location + delta, length: revealTrigger.length),
            revealStyle: revealStyle
        )
    }

    // MARK: - Фабрики

    /// Для одного BlockReference (см. BlockReferenceParser.swift).
    static func forBlockReference(_ ref: BlockReference) -> ConcealableMarker {
        ConcealableMarker(hideRanges: [ref.range], revealTrigger: ref.lineRange, revealStyle: .plain)
    }

    /// Один на CommentBlock (см. CommentBlockParser.swift). Скрывается контент
    /// КАЖДОЙ строки блока по отдельности (без \n — см. инвариант hideRanges);
    /// пустые строки внутри блока остаются пустыми строками (редкий случай,
    /// осознанный компромисс ради стабильной геометрии).
    static func forCommentBlock(_ block: CommentBlock, in ns: NSString) -> ConcealableMarker {
        ConcealableMarker(
            hideRanges: lineContentRanges(of: block.range, in: ns),
            revealTrigger: block.range,
            revealStyle: .codeBlock
        )
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
            // Контент строк-фенсов БЕЗ \n (инвариант hideRanges): строка остаётся
            // строкой, её схлопывает по высоте делегат — не слияние строк.
            return [ConcealableMarker(
                hideRanges: lineContentRanges(of: openFence, in: ns) + lineContentRanges(of: closeFence, in: ns),
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
    // Отступ — только пробелы/табы (`[ \t]*`, НЕ `\s*`): `\s` включает `\n`, и на
    // всём документе (.anchorsMatchLines) жадный `\s*` схватил бы перевод строки
    // перед пунктом после пустой строки — пряча его (строки визуально слипались бы).
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: "^[ \\t]*(?:[-*+]|\\d+\\.)[ \\t]", options: [.anchorsMatchLines]
    )

    /// Разбивает диапазон на по-строчные под-диапазоны БЕЗ символов перевода
    /// строки (инвариант hideRanges). Пустые строки пропускаются — скрывать в
    /// них нечего.
    static func lineContentRanges(of range: NSRange, in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var location = range.location
        let end = min(NSMaxRange(range), ns.length)
        while location < end {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = min(NSMaxRange(line), end)
            while contentEnd > location {
                let c = ns.character(at: contentEnd - 1)
                if c == 0x0A || c == 0x0D { contentEnd -= 1 } else { break }
            }
            let start = max(line.location, range.location)
            if contentEnd > start {
                result.append(NSRange(location: start, length: contentEnd - start))
            }
            location = NSMaxRange(line)
        }
        return result
    }

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
