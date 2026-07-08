// BlockReferenceParserTests.swift — тесты блок-ссылок Obsidian `^id` (переделка редактора).
//
// Покрытие: конец строки, обязательный пробел перед «^», ложные срабатывания
// (посреди слова/предложения, с хвостовой пунктуацией), исключение в код-блоке,
// кириллица/UTF-16, несколько ссылок в документе.

import XCTest
@testable import SecondBrain

final class BlockReferenceParserTests: XCTestCase {

    func testDetectsBlockRefAtEndOfLine() {
        let refs = BlockReferenceParser.parse("текст ^abc123")
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].id, "abc123")
    }

    func testRequiresPrecedingWhitespace() {
        XCTAssertTrue(BlockReferenceParser.parse("текст^abc123").isEmpty)
    }

    func testNotMatchedMidSentence() {
        XCTAssertTrue(BlockReferenceParser.parse("решить x^2 через степень").isEmpty)
    }

    func testMatchedWithTrailingWhitespace() {
        let refs = BlockReferenceParser.parse("текст ^abc123   ")
        XCTAssertEqual(refs.map(\.id), ["abc123"])
    }

    func testNotMatchedWithTrailingPunctuation() {
        XCTAssertTrue(BlockReferenceParser.parse("текст ^abc123.").isEmpty)
    }

    func testTokenRangeCoversCaretAndID() {
        let text = "Пункт списка ^fLRCctQA"
        let ref = BlockReferenceParser.parse(text)[0]
        XCTAssertEqual((text as NSString).substring(with: ref.range), "^fLRCctQA")
    }

    func testLineRangeCoversWholeLine() {
        let text = "первая строка\nТг Канал ^fLRCctQA\nтретья строка"
        let ref = BlockReferenceParser.parse(text)[0]
        XCTAssertEqual((text as NSString).substring(with: ref.lineRange), "Тг Канал ^fLRCctQA\n")
    }

    func testCyrillicRangesAreValidUTF16() {
        let text = "Финансы и активы: закрыть ипотеку 🏦 ^abc123"
        let ns = text as NSString
        let ref = BlockReferenceParser.parse(text)[0]
        XCTAssertLessThanOrEqual(ref.range.location + ref.range.length, ns.length)
    }

    func testIgnoredInsideFencedCodeBlock() {
        let text = """
        обычная ссылка ^outside

        ```
        код ^insideCode
        ```
        """
        let ids = BlockReferenceParser.parse(text).map(\.id)
        XCTAssertEqual(ids, ["outside"])
    }

    func testMultipleBlockRefsInDocument() {
        let text = """
        Тг Канал ^fLRCctQA

        Ютуб Канал (+ Рутуб)
        - Разборы задач
        - System Design ^HRHTvYTa
        """
        let ids = BlockReferenceParser.parse(text).map(\.id)
        XCTAssertEqual(ids, ["fLRCctQA", "HRHTvYTa"])
    }

    func testHyphenAllowedInID() {
        XCTAssertEqual(BlockReferenceParser.parse("текст ^abc-123").map(\.id), ["abc-123"])
    }
}
