// ParagraphStylingTests.swift — тесты группировки абзацев и отступов (переделка редактора).
//
// Покрытие: группировка обычных строк, разрыв пустой строкой, заголовок всегда
// один, уровни заголовков, списки построчно (с вложенностью), цитата группируется,
// точные числа стилей — регрессия на таблицу из плана.

import XCTest
@testable import SecondBrain

final class ParagraphStylingTests: XCTestCase {

    func testGroupsConsecutiveBodyLinesIntoOneParagraph() {
        let text = "строка раз\nстрока два\nстрока три"
        let paragraphs = ParagraphStyling.paragraphRanges(in: text)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].kind, .body)
        XCTAssertEqual((text as NSString).substring(with: paragraphs[0].range), text)
    }

    func testBlankLineSeparatesParagraphs() {
        let text = "первый абзац\n\nвторой абзац"
        let paragraphs = ParagraphStyling.paragraphRanges(in: text)
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.map(\.kind), [.body, .body])
    }

    func testEachHeadingIsOwnParagraphEvenAdjacentToText() {
        let text = "# Заголовок\nобычный текст без пустой строки"
        let paragraphs = ParagraphStyling.paragraphRanges(in: text)
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0].kind, .heading(level: 1))
        XCTAssertEqual(paragraphs[1].kind, .body)
    }

    func testHeadingLevelDetection() {
        let text = "# H1\n## H2\n### H3\n#### H4"
        let kinds = ParagraphStyling.paragraphRanges(in: text).map(\.kind)
        XCTAssertEqual(kinds, [.heading(level: 1), .heading(level: 2), .heading(level: 3), .heading(level: 4)])
    }

    func testListItemsEachGetOwnParagraphRange() {
        let text = "- пункт раз\n- пункт два\n- пункт три"
        let paragraphs = ParagraphStyling.paragraphRanges(in: text)
        XCTAssertEqual(paragraphs.count, 3)
        XCTAssertTrue(paragraphs.allSatisfy { $0.kind == .listItem(indentLevel: 0) })
    }

    func testNestedListIndentLevelComputed() {
        let text = "- верхний\n  - вложенный"
        let kinds = ParagraphStyling.paragraphRanges(in: text).map(\.kind)
        XCTAssertEqual(kinds, [.listItem(indentLevel: 0), .listItem(indentLevel: 1)])
    }

    func testChecklistLinesClassifiedAsListItems() {
        // Чеклист — тоже список: детектор "- "/"* "/"+ " ловит и "- [ ] текст".
        let kinds = ParagraphStyling.paragraphRanges(in: "- [ ] задача\n- [x] готово").map(\.kind)
        XCTAssertEqual(kinds, [.listItem(indentLevel: 0), .listItem(indentLevel: 0)])
    }

    func testBlockquoteLinesGrouped() {
        let text = "> первая строка цитаты\n> вторая строка той же цитаты"
        let paragraphs = ParagraphStyling.paragraphRanges(in: text)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].kind, .blockquote)
    }

    func testMixedDocumentProducesExpectedSequence() {
        let text = """
        # Заголовок

        Обычный абзац
        из двух строк.

        - пункт раз
        - пункт два

        > цитата
        """
        let kinds = ParagraphStyling.paragraphRanges(in: text).map(\.kind)
        XCTAssertEqual(kinds, [
            .heading(level: 1),
            .body,
            .listItem(indentLevel: 0),
            .listItem(indentLevel: 0),
            .blockquote
        ])
    }

    func testEmptyTextProducesNoParagraphs() {
        XCTAssertTrue(ParagraphStyling.paragraphRanges(in: "").isEmpty)
    }

    // MARK: - style(for:) — регрессия на конкретные числа

    func testStyleValuesForHeadings() {
        let h1 = ParagraphStyling.style(for: .heading(level: 1))
        XCTAssertEqual(h1.paragraphSpacingBefore, 24)
        XCTAssertEqual(h1.paragraphSpacing, 12)

        let h2 = ParagraphStyling.style(for: .heading(level: 2))
        XCTAssertEqual(h2.paragraphSpacingBefore, 20)
        XCTAssertEqual(h2.paragraphSpacing, 10)

        let h3 = ParagraphStyling.style(for: .heading(level: 3))
        XCTAssertEqual(h3.paragraphSpacingBefore, 16)
        XCTAssertEqual(h3.paragraphSpacing, 8)

        let h4 = ParagraphStyling.style(for: .heading(level: 4))
        XCTAssertEqual(h4.paragraphSpacingBefore, 12)
        XCTAssertEqual(h4.paragraphSpacing, 6)
    }

    func testStyleValuesForBody() {
        let style = ParagraphStyling.style(for: .body)
        XCTAssertEqual(style.lineSpacing, 5)
        XCTAssertEqual(style.paragraphSpacing, 10)
    }

    func testStyleValuesForListItem() {
        let top = ParagraphStyling.style(for: .listItem(indentLevel: 0))
        XCTAssertEqual(top.headIndent, 24)
        XCTAssertEqual(top.firstLineHeadIndent, 0)

        let nested = ParagraphStyling.style(for: .listItem(indentLevel: 1))
        XCTAssertEqual(nested.headIndent, 44)
        XCTAssertEqual(nested.firstLineHeadIndent, 24)
    }

    func testStyleValuesForBlockquote() {
        let style = ParagraphStyling.style(for: .blockquote)
        XCTAssertEqual(style.headIndent, 20)
        XCTAssertEqual(style.firstLineHeadIndent, 20)
        XCTAssertEqual(style.paragraphSpacingBefore, 6)
    }
}
