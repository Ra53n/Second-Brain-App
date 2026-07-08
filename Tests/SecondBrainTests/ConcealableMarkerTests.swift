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

    func testCodeBlockProducesFenceLineRanges() {
        let text = "```kotlin\nfun a() {}\nfun b() {}\n```"
        let ns = text as NSString
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .codeBlock }!
        let markers = ConcealableMarker.forHighlighterMatch(match, in: ns)

        XCTAssertEqual(markers.count, 1)
        let marker = markers[0]
        XCTAssertEqual(marker.hideRanges.count, 2)
        XCTAssertEqual(ns.substring(with: marker.hideRanges[0]), "```kotlin\n")
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
