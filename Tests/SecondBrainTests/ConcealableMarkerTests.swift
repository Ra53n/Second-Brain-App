// ConcealableMarkerTests.swift — тесты фабрик единой модели сворачивания
// (Live Preview: заголовки, жирный, выделение, инлайн-код, код-блок, цитата,
// wikilink-скобки, списки, блок-ссылки, %%-комментарии).
//
// Покрытие: hideRanges/revealTrigger для каждого вида, арифметика границ
// код-блока, вложенные списки, совпадение revealTrigger у двух маркеров на
// одной строке (не мешают друг другу), кириллица/UTF-16.

import XCTest
@testable import SecondBrain

final class ConcealableMarkerTests: XCTestCase {

    // MARK: - forHighlighterMatch: однострочные маркеры

    func testHeadingProducesOneHideRangeWithLineTrigger() {
        let text = "# Заголовок\nследующая строка"
        let ns = text as NSString
        let match = MarkdownHighlighter.matches(in: text).first { if case .heading = $0.kind { return true }; return false }!
        let markers = ConcealableMarker.forHighlighterMatch(match, in: ns)

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].hideRanges.map { ns.substring(with: $0) }, ["#"])
        XCTAssertEqual(ns.substring(with: markers[0].revealTrigger), "# Заголовок\n")
        XCTAssertEqual(markers[0].revealStyle, .plain)
    }

    func testBoldProducesTwoHideRangesWithLineTrigger() {
        let text = "тут **жирный** текст"
        let ns = text as NSString
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .bold }!
        let markers = ConcealableMarker.forHighlighterMatch(match, in: ns)

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].hideRanges.count, 2)
        XCTAssertEqual(ns.substring(with: markers[0].revealTrigger), text)
    }

    func testBlockquoteHideRangeExcludesContent() {
        let text = "> цитата тут"
        let ns = text as NSString
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .blockquote }!
        let markers = ConcealableMarker.forHighlighterMatch(match, in: ns)

        XCTAssertEqual(markers[0].hideRanges.map { ns.substring(with: $0) }, ["> "])
    }

    // MARK: - forHighlighterMatch: code fences (многострочный блок)

    func testCodeBlockProducesFenceLineRangesWithoutNewlines() {
        // Контент строк-фенсов БЕЗ \n: строка остаётся строкой (её схлопывает по
        // высоте делегат) — нуллификация \n сливала строки и ломала геометрию.
        let text = "```kotlin\nfun a() {}\nfun b() {}\n```"
        let ns = text as NSString
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .codeBlock }!
        let markers = ConcealableMarker.forHighlighterMatch(match, in: ns)

        XCTAssertEqual(markers.count, 1)
        let marker = markers[0]
        XCTAssertEqual(marker.hideRanges.count, 2)
        XCTAssertEqual(ns.substring(with: marker.hideRanges[0]), "```kotlin")
        XCTAssertEqual(ns.substring(with: marker.hideRanges[1]), "```")
        XCTAssertEqual(marker.revealStyle, .codeBlock)
    }

    func testCodeBlockRevealTriggerSpansWholeBlock() {
        let text = "```\nкод\n```"
        let ns = text as NSString
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .codeBlock }!
        let marker = ConcealableMarker.forHighlighterMatch(match, in: ns)[0]

        XCTAssertEqual(marker.revealTrigger, match.range)
    }

    func testMinimalEmptyCodeBlockFenceRangesDoNotOverlap() {
        let text = "```\n```"
        let ns = text as NSString
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .codeBlock }!
        let marker = ConcealableMarker.forHighlighterMatch(match, in: ns)[0]

        XCTAssertEqual(NSIntersectionRange(marker.hideRanges[0], marker.hideRanges[1]).length, 0)
    }

    func testNoFactoryEverHidesNewlines() {
        // Инвариант hideRanges: переводы строк не скрываются никогда.
        let text = "# Заголовок\n\n- пункт **жирный** `код`\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n%% многострочный\nкомментарий %%\nтекст [[Ссылка]] ^ref1\n"
        let ns = text as NSString
        var allHideRanges: [NSRange] = []
        for match in MarkdownHighlighter.matches(in: text) {
            allHideRanges += ConcealableMarker.forHighlighterMatch(match, in: ns).flatMap(\.hideRanges)
        }
        allHideRanges += CommentBlockParser.parse(text).map { ConcealableMarker.forCommentBlock($0, in: ns) }.flatMap(\.hideRanges)
        allHideRanges += WikilinkParser.parse(text).map(ConcealableMarker.forWikilink).flatMap(\.hideRanges)
        allHideRanges += BlockReferenceParser.parse(text).map(ConcealableMarker.forBlockReference).flatMap(\.hideRanges)
        allHideRanges += ConcealableMarker.forListMarkers(in: text).flatMap(\.hideRanges)

        XCTAssertFalse(allHideRanges.isEmpty)
        for range in allHideRanges {
            let s = ns.substring(with: range)
            XCTAssertFalse(s.contains("\n"), "hideRange содержит \\n: [\(s)]")
            XCTAssertFalse(s.contains("\r"), "hideRange содержит \\r: [\(s)]")
        }
    }

    func testCommentBlockHidesEachLineSeparately() {
        let text = "до\n%% раз\nдва\nтри %%\nпосле"
        let ns = text as NSString
        let block = CommentBlockParser.parse(text)[0]
        let marker = ConcealableMarker.forCommentBlock(block, in: ns)

        XCTAssertEqual(marker.hideRanges.map { ns.substring(with: $0) }, ["%% раз", "два", "три %%"])
        XCTAssertEqual(marker.revealTrigger, block.range)
    }

    // MARK: - lineContentRanges

    func testLineContentRangesSplitsAndStripsNewlines() {
        let text = "первая\nвторая\nтретья"
        let ns = text as NSString
        let ranges = ConcealableMarker.lineContentRanges(of: NSRange(location: 0, length: ns.length), in: ns)
        XCTAssertEqual(ranges.map { ns.substring(with: $0) }, ["первая", "вторая", "третья"])
    }

    func testLineContentRangesSkipsEmptyLines() {
        let text = "раз\n\nдва"
        let ns = text as NSString
        let ranges = ConcealableMarker.lineContentRanges(of: NSRange(location: 0, length: ns.length), in: ns)
        XCTAssertEqual(ranges.map { ns.substring(with: $0) }, ["раз", "два"])
    }

    func testLineContentRangesRespectsPartialFirstLine() {
        // Диапазон начинается посреди строки (инлайн-комментарий).
        let text = "текст %%скрыто%% хвост"
        let ns = text as NSString
        let inner = ns.range(of: "%%скрыто%%")
        let ranges = ConcealableMarker.lineContentRanges(of: inner, in: ns)
        XCTAssertEqual(ranges.map { ns.substring(with: $0) }, ["%%скрыто%%"])
    }

    // MARK: - forWikilink

    func testWikilinkPlainProducesBracketHideRangesAndTargetVisible() {
        let text = "текст [[Заметка]] тут"
        let link = WikilinkParser.parse(text)[0]
        let marker = ConcealableMarker.forWikilink(link)
        let ns = text as NSString

        XCTAssertEqual(marker.hideRanges.map { ns.substring(with: $0) }, ["[[", "]]"])
        XCTAssertEqual(marker.revealTrigger, link.range)
    }

    func testWikilinkAliasedProducesPrefixSuffixHideRangesAndAliasVisible() {
        let text = "[[Заметка|алиас]]"
        let link = WikilinkParser.parse(text)[0]
        let marker = ConcealableMarker.forWikilink(link)
        let ns = text as NSString

        XCTAssertEqual(marker.hideRanges.map { ns.substring(with: $0) }, ["[[Заметка|", "]]"])
    }

    // MARK: - forListMarkers

    func testListMarkerHidesIndentAndBulletTogether() {
        let text = "- пункт списка"
        let markers = ConcealableMarker.forListMarkers(in: text)
        let ns = text as NSString

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(ns.substring(with: markers[0].hideRanges[0]), "- ")
        XCTAssertEqual(ns.substring(with: markers[0].revealTrigger), text)
    }

    func testNestedListMarkerHidesLeadingWhitespaceToo() {
        let text = "- верхний\n  - вложенный"
        let markers = ConcealableMarker.forListMarkers(in: text)
        let ns = text as NSString

        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(ns.substring(with: markers[1].hideRanges[0]), "  - ")
    }

    func testNumberedListMarkerDetected() {
        let markers = ConcealableMarker.forListMarkers(in: "1. первый\n2. второй")
        XCTAssertEqual(markers.count, 2)
    }

    func testChecklistLineAlsoCountsAsListMarker() {
        // "- [ ] задача" начинается с "- " — детектор списка ловит его тоже;
        // сами скобки [ ]/[x] чеклиста сворачиванием не занимается (ChecklistParser
        // отдельно, они кликабельны и должны быть видимы всегда).
        let markers = ConcealableMarker.forListMarkers(in: "- [ ] задача")
        XCTAssertEqual(markers.count, 1)
    }

    func testListMarkerIgnoredInsideCodeBlock() {
        let text = "```\n- не список, это код\n```"
        XCTAssertTrue(ConcealableMarker.forListMarkers(in: text).isEmpty)
    }

    // MARK: - Интеграционные: несколько маркеров на одной строке

    func testHeadingAndTrailingBlockRefShareSameLineTrigger() {
        let text = "# Заголовок ^abc123"
        let ns = text as NSString

        let headingMatch = MarkdownHighlighter.matches(in: text).first { if case .heading = $0.kind { return true }; return false }!
        let headingMarker = ConcealableMarker.forHighlighterMatch(headingMatch, in: ns)[0]

        let ref = BlockReferenceParser.parse(text)[0]
        let refMarker = ConcealableMarker.forBlockReference(ref)

        XCTAssertEqual(headingMarker.revealTrigger, refMarker.revealTrigger)
    }

    func testBlockquoteAndBoldOnSameLineConcealIndependently() {
        let text = "> текст **жирный** тут"
        let ns = text as NSString
        let matches = MarkdownHighlighter.matches(in: text)

        let blockquoteMarker = ConcealableMarker.forHighlighterMatch(matches.first { $0.kind == .blockquote }!, in: ns)[0]
        let boldMarker = ConcealableMarker.forHighlighterMatch(matches.first { $0.kind == .bold }!, in: ns)[0]

        // Один и тот же триггер (строка), но разные (непересекающиеся) hideRanges.
        XCTAssertEqual(blockquoteMarker.revealTrigger, boldMarker.revealTrigger)
        for hide in blockquoteMarker.hideRanges {
            for otherHide in boldMarker.hideRanges {
                XCTAssertEqual(NSIntersectionRange(hide, otherHide).length, 0)
            }
        }
    }

    // MARK: - Кириллица/UTF-16

    func testCyrillicHideRangesAreValidUTF16() {
        let text = "## Финансы и активы 🏦\n**жирное слово** и [[Заметка|алиас]]"
        let ns = text as NSString
        var allHideRanges: [NSRange] = []

        for match in MarkdownHighlighter.matches(in: text) {
            allHideRanges += ConcealableMarker.forHighlighterMatch(match, in: ns).flatMap(\.hideRanges)
        }
        for link in WikilinkParser.parse(text) {
            allHideRanges += ConcealableMarker.forWikilink(link).hideRanges
        }

        for range in allHideRanges {
            XCTAssertLessThanOrEqual(range.location + range.length, ns.length)
        }
        XCTAssertFalse(allHideRanges.isEmpty)
    }
}
