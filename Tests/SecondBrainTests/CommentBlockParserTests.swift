// CommentBlockParserTests.swift — тесты скрытых Obsidian-комментариев `%% ... %%`.
//
// Покрытие: однострочный, многострочный (форма Excalidraw-плагина), незакрытый
// (hide-to-EOF), несколько последовательных блоков (попарная привязка 1-2/3-4),
// маркер внутри код-блока не считается.

import XCTest
@testable import SecondBrain

final class CommentBlockParserTests: XCTestCase {

    func testSingleLineComment() {
        let text = "до %%скрыто%% после"
        let blocks = CommentBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].isTerminated)
        XCTAssertEqual((text as NSString).substring(with: blocks[0].range), "%%скрыто%%")
    }

    func testMultilineComment() {
        // Форма, в которой Excalidraw-плагин прячет JSON рисунка.
        let text = """
        видимый текст

        %%
        ## Drawing
        ```compressed-json
        N4KAkARALg
        ```
        %%
        """
        let blocks = CommentBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].isTerminated)
        let content = (text as NSString).substring(with: blocks[0].range)
        XCTAssertTrue(content.hasPrefix("%%\n## Drawing"))
        XCTAssertTrue(content.hasSuffix("%%"))
    }

    func testUnterminatedCommentHidesToEOF() {
        let text = "текст до\n%%\nоткрыт и не закрыт\nдо самого конца"
        let blocks = CommentBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertFalse(blocks[0].isTerminated)
        XCTAssertEqual(NSMaxRange(blocks[0].range), (text as NSString).length)
    }

    func testMultipleSequentialBlocksPairedCorrectly() {
        let text = "%%раз%% между %%два%%"
        let blocks = CommentBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual((text as NSString).substring(with: blocks[0].range), "%%раз%%")
        XCTAssertEqual((text as NSString).substring(with: blocks[1].range), "%%два%%")
    }

    func testCommentMarkerInsideCodeBlockIgnored() {
        let text = """
        ```
        текст с %% внутри кода
        ```
        обычный %%комментарий%% снаружи
        """
        let blocks = CommentBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual((text as NSString).substring(with: blocks[0].range), "%%комментарий%%")
    }

    func testEmptyDocumentReturnsNoBlocks() {
        XCTAssertTrue(CommentBlockParser.parse("").isEmpty)
    }

    func testNoCommentMarkersReturnsEmpty() {
        XCTAssertTrue(CommentBlockParser.parse("обычный текст без комментариев").isEmpty)
    }

    func testCyrillicAndBase64LikeContentRangeValid() {
        let text = "Финансы и активы %%\nN4KAkARALgngDgUwgLg\nZwBmJPj1roBGAHZ\n%%"
        let ns = text as NSString
        let blocks = CommentBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertLessThanOrEqual(NSMaxRange(blocks[0].range), ns.length)
    }
}
