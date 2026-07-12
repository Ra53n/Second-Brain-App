// MeetingPromptsTests.swift — парсер ответа LLM (TITLE:/FOLDER:/SUMMARY:) и
// чанкование транскрипта для map-reduce. Критерии задачи 11: полный,
// частичный и мусорный ответ.

import XCTest
@testable import SecondBrain

final class MeetingPromptsTests: XCTestCase {

    // MARK: - Парсер ответа

    func testParseFullResponse() {
        let text = """
        TITLE: Синк по релизу 3.2
        FOLDER: Работа/Релизы
        SUMMARY:
        Обсудили сроки.
        Решили перенести на неделю.
        """
        let parsed = MeetingPrompts.parseSummaryResponse(text)
        XCTAssertEqual(parsed.title, "Синк по релизу 3.2")
        XCTAssertEqual(parsed.folder, "Работа/Релизы")
        XCTAssertEqual(parsed.summary, "Обсудили сроки.\nРешили перенести на неделю.")
    }

    func testParseIsCaseInsensitiveAndTrimsWhitespace() {
        let text = "  title: Планёрка  \nfolder:  Команда \nsummary: Коротко."
        let parsed = MeetingPrompts.parseSummaryResponse(text)
        XCTAssertEqual(parsed.title, "Планёрка")
        XCTAssertEqual(parsed.folder, "Команда")
        XCTAssertEqual(parsed.summary, "Коротко.")
    }

    func testParsePartialResponseOnlySummary() {
        let text = "SUMMARY:\nТолько конспект, названия нет."
        let parsed = MeetingPrompts.parseSummaryResponse(text)
        XCTAssertNil(parsed.title)
        XCTAssertNil(parsed.folder)
        XCTAssertEqual(parsed.summary, "Только конспект, названия нет.")
    }

    func testParsePartialResponseMissingSummaryMarker() {
        // Модель дала TITLE и сразу текст без SUMMARY: — текст не теряем.
        let text = "TITLE: Встреча с дизайном\nОбсудили макеты, всё ок."
        let parsed = MeetingPrompts.parseSummaryResponse(text)
        XCTAssertEqual(parsed.title, "Встреча с дизайном")
        XCTAssertEqual(parsed.summary, "Обсудили макеты, всё ок.")
    }

    func testParseGarbageBecomesSummary() {
        let text = "Модель проигнорировала формат и просто написала абзац текста."
        let parsed = MeetingPrompts.parseSummaryResponse(text)
        XCTAssertNil(parsed.title)
        XCTAssertNil(parsed.folder)
        XCTAssertEqual(parsed.summary, text)
    }

    func testParseEmptyMarkersGiveNil() {
        let text = "TITLE:\nFOLDER:\nSUMMARY:\nЕсть только конспект."
        let parsed = MeetingPrompts.parseSummaryResponse(text)
        XCTAssertNil(parsed.title, "пустое значение маркера — как отсутствие")
        XCTAssertNil(parsed.folder)
        XCTAssertEqual(parsed.summary, "Есть только конспект.")
    }

    func testParseMultilineSummaryKeepsMarkerLookingLines() {
        // Внутри summary строка «TITLE:…» — часть конспекта, не второй маркер.
        let text = """
        TITLE: Ретро
        SUMMARY:
        Пункт 1.
        TITLE: этой строки не должно быть в title
        """
        let parsed = MeetingPrompts.parseSummaryResponse(text)
        XCTAssertEqual(parsed.title, "Ретро")
        XCTAssertTrue(parsed.summary.contains("TITLE: этой строки"))
    }

    // MARK: - Чанкование

    func testShortTranscriptSingleChunk() {
        let chunks = MeetingPrompts.chunkTranscript("короткий текст", maxChars: 100)
        XCTAssertEqual(chunks, ["короткий текст"])
    }

    func testEmptyTranscriptNoChunks() {
        XCTAssertEqual(MeetingPrompts.chunkTranscript("   \n  ", maxChars: 100), [])
    }

    func testLongTranscriptSplitsOnParagraphs() {
        let paragraph = String(repeating: "а", count: 60)
        let text = ([paragraph, paragraph, paragraph]).joined(separator: "\n")
        let chunks = MeetingPrompts.chunkTranscript(text, maxChars: 130)
        XCTAssertEqual(chunks.count, 2, "3×60 символов при лимите 130 → 2 чанка")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 130)
        }
        // Ничего не потеряли.
        XCTAssertEqual(chunks.joined(separator: "\n").replacingOccurrences(of: "\n", with: ""),
                       text.replacingOccurrences(of: "\n", with: ""))
    }

    func testMonsterParagraphHardSplit() {
        let text = String(repeating: "б", count: 250)
        let chunks = MeetingPrompts.chunkTranscript(text, maxChars: 100)
        XCTAssertEqual(chunks.count, 3) // 100 + 100 + 50
        XCTAssertEqual(chunks.joined().count, 250)
    }
}
