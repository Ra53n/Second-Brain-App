// PreviewFilterTests.swift — тесты препроцессинга превью (переделка редактора).
//
// Покрытие: вырезание комментариев (одно-/многострочных/незакрытых), вырезание
// хвостовых `^id`, замена `==`→`**`, порядок операций (не подсвечивать то, что
// уже вырезано вместе с комментарием), фикстура-миниатюра под Excalidraw-файл.

import XCTest
@testable import SecondBrain

final class PreviewFilterTests: XCTestCase {

    func testStripsSingleLineCommentBlock() {
        XCTAssertEqual(PreviewFilter.apply("до %%скрыто%% после"), "до  после")
    }

    func testStripsMultilineCommentBlockEntirely() {
        let text = """
        видимый текст

        %%
        ## Drawing
        ```compressed-json
        N4KAkARALg
        ```
        %%
        """
        let result = PreviewFilter.apply(text)
        XCTAssertEqual(result, "видимый текст\n\n")
    }

    func testStripsUnterminatedCommentToEOF() {
        let text = "видимый текст\n%%\nдо конца документа"
        XCTAssertEqual(PreviewFilter.apply(text), "видимый текст\n")
    }

    func testStripsTrailingBlockRefAndPrecedingSpace() {
        XCTAssertEqual(PreviewFilter.apply("Пункт списка ^fLRCctQA"), "Пункт списка")
    }

    func testStripsMultipleBlockRefsAcrossLines() {
        let text = "Тг Канал ^fLRCctQA\n\nЮтуб Канал ^HRHTvYTa"
        XCTAssertEqual(PreviewFilter.apply(text), "Тг Канал\n\nЮтуб Канал")
    }

    func testReplacesHighlightWithBold() {
        XCTAssertEqual(PreviewFilter.apply("==важно=="), "**важно**")
    }

    func testOrderOfOperationsHandlesOverlap() {
        // «==»/«^id» внутри спрятанного блока не должны просочиться как жирный
        // текст/ссылка после фильтрации — комментарий вырезается целиком первым.
        let text = "видимый %%скрытый ==не должен стать жирным== ^abc123%% текст"
        let result = PreviewFilter.apply(text)
        XCTAssertFalse(result.contains("**"))
        XCTAssertFalse(result.contains("^abc123"))
    }

    func testPlainTextUnaffected() {
        let text = "Обычная заметка без специального синтаксиса."
        XCTAssertEqual(PreviewFilter.apply(text), text)
    }

    func testRealExcalidrawFixtureProducesCleanPreviewText() {
        let text = """
        ---

        excalidraw-plugin: parsed
        tags: [excalidraw]

        ---
        ==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠==

        # Excalidraw Data

        ## Text Elements
        Тг Канал ^fLRCctQA

        Ютуб Канал (+ Рутуб)
        - Разборы задач
        - System Design ^HRHTvYTa

        %%
        ## Drawing
        ```compressed-json
        N4KAkARALgngDgUwgLgAQQQDwMYEMA2AlgCYBOuA7hADTgQBuCpAzoQPYB2KqATLZMzYBXUtiRoIACyhQ4zZAHoFAc0JRJQgEYA6bGwC2CgF7N6hbEcK4OCtptbErHALRY8RMpWdx8Q1TdIEfARcZgRmBShcZQUebQBObR4aOiCEfQQOKGZuAG1wMFAwYogSbggAKXxMAHUAcRqoAGlsTAArHgAGADZ6AC0+tuwARTqU4shYRHLA7CiOZWDxksxu
        ```
        %%
        """
        let result = PreviewFilter.apply(text)

        XCTAssertFalse(result.contains("%%"))
        XCTAssertFalse(result.contains("compressed-json"))
        XCTAssertFalse(result.contains("^fLRCctQA"))
        XCTAssertFalse(result.contains("^HRHTvYTa"))
        XCTAssertFalse(result.contains("=="))
        XCTAssertTrue(result.contains("**⚠  Switch to EXCALIDRAW VIEW"))
        XCTAssertTrue(result.contains("Тг Канал"))
        XCTAssertTrue(result.contains("System Design"))
    }
}
