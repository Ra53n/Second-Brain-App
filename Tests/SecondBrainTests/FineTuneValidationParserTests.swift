// FineTuneValidationParserTests.swift — задача 82: разбор вывода finetune/validate.py (P1).
//
// Контракт: заметки в stdout, ошибки в stderr (заголовок "ОШИБКИ (N):" + строки с
// отступом), isValid решает код возврата, не наличие строки "OK". Примеры вывода —
// дословно из спецификации задачи 82.

import XCTest
@testable import SecondBrain

final class FineTuneValidationParserTests: XCTestCase {
    private typealias Parser = FineTuneValidationParser
    private typealias Issue = FineTuneValidationParser.Issue

    // MARK: - Дословные примеры

    func testSuccessfulRunCollectsNotesAndDropsOkLine() {
        let stdout = """
        data/train.jsonl: 38 строк, уникальных текстов assistant 20
        train 38 (76%), остальное 12
        OK — датасет валиден
        """
        let result = Parser.parse(status: 0, stdout: stdout, stderr: "")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.notes, [
            "data/train.jsonl: 38 строк, уникальных текстов assistant 20",
            "train 38 (76%), остальное 12"
        ], "строка OK — не заметка, в список не попадает")
        XCTAssertEqual(result.issues, [])
    }

    func testFailedRunParsesLineNumberedAndBareIssues() {
        let stderr = """
        ОШИБКИ (2):
          data/train.jsonl:7: assistant 45 символов, допустимо 120–6000
          split: утечка: посты itogi_2025 есть и в train.jsonl, и в valid.jsonl
        """
        let result = Parser.parse(status: 1, stdout: "", stderr: stderr)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(result.issues, [
            Issue(file: "data/train.jsonl", line: 7, text: "assistant 45 символов, допустимо 120–6000"),
            Issue(file: nil, line: nil, text: "утечка: посты itogi_2025 есть и в train.jsonl, и в valid.jsonl")
        ])
    }

    /// Заголовок "ОШИБКИ (N):" — служебная строка, не превращается в issue.
    func testIssuesHeaderIsNotAnIssue() {
        let result = Parser.parse(status: 1, stdout: "", stderr: "ОШИБКИ (2):\n  a.jsonl:1: x\n  b.jsonl:2: y")
        XCTAssertFalse(result.issues.contains { $0.text.contains("ОШИБКИ") },
                       "заголовок не должен попасть в список ошибок")
        XCTAssertEqual(result.issues.count, 2)
    }

    /// Второе двоеточие (уже внутри текста ошибки) не должно ничего дополнительно резать.
    func testColonsInsideIssueTextDoNotBreakParsing() {
        let result = Parser.parse(status: 1, stdout: "",
                                  stderr: "split: утечка: посты a есть и в train.jsonl, и в valid.jsonl")
        XCTAssertEqual(result.issues, [
            Issue(file: nil, line: nil, text: "утечка: посты a есть и в train.jsonl, и в valid.jsonl")
        ])
    }

    func testTwoSpaceIndentIsTrimmed() {
        let result = Parser.parse(status: 1, stdout: "", stderr: "  a.jsonl:3: текст")
        XCTAssertEqual(result.issues.first?.file, "a.jsonl")
        XCTAssertEqual(result.issues.first?.line, 3)
        XCTAssertEqual(result.issues.first?.text, "текст")
    }

    // MARK: - Пусто и граница «валиден по коду, не по тексту»

    func testEmptyOutputProducesEmptyResult() {
        let result = Parser.parse(status: 0, stdout: "", stderr: "")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(result.issues, [])
    }

    /// Код 0 без строки "OK" — валиден по коду возврата, заметки при этом сохраняются.
    func testZeroStatusWithoutOkLineIsStillValidAndKeepsNotes() {
        let result = Parser.parse(status: 0, stdout: "data/train.jsonl: 10 строк\n", stderr: "")
        XCTAssertTrue(result.isValid, "решает код возврата, а не наличие строки OK")
        XCTAssertEqual(result.notes, ["data/train.jsonl: 10 строк"])
    }

    /// Ошибки в stderr при коде 0 — isValid всё равно true: контракт "код решает, не текст".
    func testErrorsInStderrWithZeroStatusStillValid() {
        let result = Parser.parse(status: 0, stdout: "OK — датасет валиден",
                                  stderr: "ОШИБКИ (1):\n  a.jsonl:1: странно при коде 0")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.notes, [], "единственная строка stdout — сама OK, заметок нет")
        XCTAssertEqual(result.issues.count, 1, "ошибки при этом видны, несмотря на isValid == true")
    }

    func testGarbageLineInStderrBecomesIssueWithoutFileOrLine() {
        let result = Parser.parse(status: 1, stdout: "", stderr: "мусорная строка без правильного формата")
        XCTAssertEqual(result.issues, [
            Issue(file: nil, line: nil, text: "мусорная строка без правильного формата")
        ])
    }

    /// Кириллица и длинное тире "–" не искажаются при разборе.
    func testCyrillicAndEnDashSurviveParsingIntact() {
        let result = Parser.parse(status: 1, stdout: "",
                                  stderr: "data/train.jsonl:7: assistant 45 символов, допустимо 120–6000")
        XCTAssertEqual(result.issues.first?.text, "assistant 45 символов, допустимо 120–6000")
        XCTAssertTrue(result.issues.first?.text.contains("–") == true, "длинное тире не искажено")
    }
}
