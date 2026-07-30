// FineTuneJSONLTests.swift — задача 81: строка train/valid.jsonl и sidecar-метаданные.
//
// Строгий порядок ролей system→user→assistant, битый JSON, кириллица и переводы
// строк внутри content сохраняются точно, sidecar обоих датасетов (посты, диктовка).

import XCTest
@testable import SecondBrain

final class FineTuneJSONLParseExampleTests: XCTestCase {

    func testValidLineParses() {
        let line = #"{"messages":[{"role":"system","content":"S"},{"role":"user","content":"U"},{"role":"assistant","content":"A"}]}"#
        let body = FineTuneJSONL.parseExample(line: line)
        XCTAssertEqual(body, FineTuneJSONL.Body(system: "S", user: "U", assistant: "A"))
    }

    func testTwoMessagesIsNil() {
        let line = #"{"messages":[{"role":"user","content":"U"},{"role":"assistant","content":"A"}]}"#
        XCTAssertNil(FineTuneJSONL.parseExample(line: line))
    }

    func testFourMessagesIsNil() {
        let line = #"{"messages":[{"role":"system","content":"S"},{"role":"user","content":"U"},{"role":"assistant","content":"A"},{"role":"user","content":"U2"}]}"#
        XCTAssertNil(FineTuneJSONL.parseExample(line: line))
    }

    func testWrongRoleOrderIsNil() {
        let line = #"{"messages":[{"role":"system","content":"S"},{"role":"assistant","content":"A"},{"role":"user","content":"U"}]}"#
        XCTAssertNil(FineTuneJSONL.parseExample(line: line), "assistant раньше user — не наш формат")
    }

    func testForeignRoleIsNil() {
        let line = #"{"messages":[{"role":"system","content":"S"},{"role":"tool","content":"U"},{"role":"assistant","content":"A"}]}"#
        XCTAssertNil(FineTuneJSONL.parseExample(line: line))
    }

    func testBrokenJSONIsNil() {
        XCTAssertNil(FineTuneJSONL.parseExample(line: "{ не json"))
    }

    func testEmptyLineIsNil() {
        XCTAssertNil(FineTuneJSONL.parseExample(line: ""))
    }

    /// Кириллица и экранированные переводы строк внутри content — сохраняются дословно.
    func testCyrillicAndNewlinesPreservedExactly() {
        let expectedUser = "Заметка:\nвторая строка — эмодзи 🚀"
        let line = #"{"messages":[{"role":"system","content":"Ты — ассистент."},{"role":"user","content":"Заметка:\nвторая строка — эмодзи 🚀"},{"role":"assistant","content":"Готово."}]}"#
        let body = FineTuneJSONL.parseExample(line: line)
        XCTAssertEqual(body?.user, expectedUser)
        XCTAssertEqual(body?.system, "Ты — ассистент.")
        XCTAssertEqual(body?.assistant, "Готово.")
    }

    /// messages не массив, а объект — decodable проваливается, не крашит.
    func testMessagesNotArrayIsNil() {
        let line = #"{"messages":{"role":"system","content":"S"}}"#
        XCTAssertNil(FineTuneJSONL.parseExample(line: line))
    }
}

final class FineTuneJSONLParseMetaTests: XCTestCase {

    /// Полная строка меты датасета постов.
    func testPostsDatasetMetaLine() {
        let line = #"{"id":"post-1","source_post":"2024-01-post","task_type":"summarize"}"#
        let meta = FineTuneJSONL.parseMeta(line: line)
        XCTAssertEqual(meta?.id, "post-1")
        XCTAssertEqual(meta?.sourcePost, "2024-01-post")
        XCTAssertEqual(meta?.taskType, "summarize")
        XCTAssertNil(meta?.app)
        XCTAssertNil(meta?.handEdited)
        XCTAssertNil(meta?.timestamp)
    }

    /// Полная строка меты датасета диктовки: плюс app, hand_edited, timestamp.
    func testDictationDatasetMetaLine() {
        let line = #"{"id":"d-1","source_post":"","task_type":"dictation","app":"Notes","hand_edited":true,"timestamp":"2026-07-31T10:00:00Z"}"#
        let meta = FineTuneJSONL.parseMeta(line: line)
        XCTAssertEqual(meta?.id, "d-1")
        XCTAssertEqual(meta?.taskType, "dictation")
        XCTAssertEqual(meta?.app, "Notes")
        XCTAssertEqual(meta?.handEdited, true)
        XCTAssertEqual(meta?.timestamp, "2026-07-31T10:00:00Z")
    }

    /// Строка без task_type — поле дефолтится, не роняет разбор.
    func testMissingTaskTypeDefaultsToEmpty() {
        let line = #"{"id":"post-2","source_post":"x"}"#
        let meta = FineTuneJSONL.parseMeta(line: line)
        XCTAssertEqual(meta?.taskType, "")
    }

    /// Незнакомые поля из будущих версий не ломают декод.
    func testUnknownFieldsDoNotBreakDecode() {
        let line = #"{"id":"post-3","source_post":"x","task_type":"t","future_field":"z","score":0.9}"#
        let meta = FineTuneJSONL.parseMeta(line: line)
        XCTAssertEqual(meta?.id, "post-3")
        XCTAssertEqual(meta?.taskType, "t")
    }

    func testBrokenJSONMetaIsNil() {
        XCTAssertNil(FineTuneJSONL.parseMeta(line: "{ битый"))
    }

    func testEmptyLineMetaIsNil() {
        XCTAssertNil(FineTuneJSONL.parseMeta(line: ""))
    }
}
