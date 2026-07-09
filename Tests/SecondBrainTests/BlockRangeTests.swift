// BlockRangeTests.swift — расширение диапазона правки до объемлющего блока
// (BlockRange.enclosingBlock) + сдвиг диапазонов (shifted).
//
// Инкрементальная подсветка перекрашивает только блок вокруг правки — здесь
// проверяем, что блок берётся корректно (границы — пустые строки), не выходит за
// пределы документа и валиден в UTF-16 (кириллица/эмодзи).

import XCTest
@testable import SecondBrain

final class BlockRangeTests: XCTestCase {

    private func block(_ text: String, at location: Int, length: Int = 0) -> NSRange {
        BlockRange.enclosingBlock(of: NSRange(location: location, length: length), in: text as NSString)
    }

    func testMidParagraphReturnsWholeBlankDelimitedParagraph() {
        let text = "первая строка\nвторая строка\nтретья строка"
        // Правка во второй строке → весь абзац (нет пустых строк — весь текст).
        let ns = text as NSString
        let result = block(text, at: 20)
        XCTAssertEqual(result, NSRange(location: 0, length: ns.length))
    }

    func testBlankLinesBoundTheBlock() {
        // Три абзаца, разделённые пустыми строками. Правка во втором не должна
        // захватывать соседние.
        let text = "aaa\n\nbbb\nBBB\n\nccc"
        let ns = text as NSString
        let secondStart = (text as NSString).range(of: "bbb").location
        let result = block(text, at: secondStart + 1)
        // Блок — обе непустые строки со своими терминаторами (семантика lineRange:
        // строка включает завершающий \n), до пустой строки-разделителя.
        let expected = ns.range(of: "bbb\nBBB\n")
        XCTAssertEqual(result, expected)
    }

    func testEditAtDocumentStart() {
        let text = "заголовок\n\nтекст"
        let result = block(text, at: 0)
        XCTAssertEqual(result, (text as NSString).range(of: "заголовок\n"))
    }

    func testEditAtDocumentEndDoesNotOverflow() {
        let text = "текст\n\nконец"
        let ns = text as NSString
        let result = block(text, at: ns.length) // каретка в самом конце
        XCTAssertLessThanOrEqual(NSMaxRange(result), ns.length)
        XCTAssertEqual(result, ns.range(of: "конец"))
    }

    func testEmptyDocumentGivesEmptyRange() {
        XCTAssertEqual(block("", at: 0), NSRange(location: 0, length: 0))
    }

    func testSingleLineNoTrailingNewline() {
        let text = "одна строка"
        XCTAssertEqual(block(text, at: 3), NSRange(location: 0, length: (text as NSString).length))
    }

    func testCyrillicAndEmojiRangesValidUTF16() {
        let text = "привет 👋 мир\n\nвторой 🎯 абзац"
        let ns = text as NSString
        for loc in 0...ns.length {
            let r = block(text, at: min(loc, ns.length))
            XCTAssertGreaterThanOrEqual(r.location, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(r), ns.length, "блок вышел за границы на позиции \(loc)")
        }
    }

    func testShiftedMovesLocationOnly() {
        XCTAssertEqual(BlockRange.shifted(NSRange(location: 5, length: 3), by: 10), NSRange(location: 15, length: 3))
        XCTAssertEqual(BlockRange.shifted(NSRange(location: 5, length: 3), by: -2), NSRange(location: 3, length: 3))
        XCTAssertEqual(BlockRange.shifted(NSRange(location: 5, length: 3), by: 0), NSRange(location: 5, length: 3))
    }
}
