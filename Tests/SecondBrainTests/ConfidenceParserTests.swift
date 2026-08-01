// ConfidenceParserTests.swift — задача 85: строгий разбор ответа модели, зеркало
// finetune/actionitem_checks.parse() (+ схема элементов из run_checks для типизации).

import XCTest
@testable import SecondBrain

final class ConfidenceParserTests: XCTestCase {

    func testValidSingleItem() {
        let items = ActionItemsParser.parse(#"{"action_items": [{"assignee": "Аня", "task": "сделать отчёт", "due": "пятница"}]}"#)
        XCTAssertEqual(items, [ActionItem(assignee: "Аня", task: "сделать отчёт", due: "пятница")])
    }

    func testValidWithNullFields() {
        let items = ActionItemsParser.parse(#"{"action_items": [{"assignee": null, "task": "сделать", "due": null}]}"#)
        XCTAssertEqual(items, [ActionItem(assignee: nil, task: "сделать", due: nil)])
    }

    func testEmptyActionItemsIsValidEmptyList() {
        XCTAssertEqual(ActionItemsParser.parse(#"{"action_items": []}"#), [])
    }

    func testBadJSONReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse("not json at all"))
        XCTAssertNil(ActionItemsParser.parse(""))
        XCTAssertNil(ActionItemsParser.parse("{"))
    }

    func testMarkdownFenceWrapperReturnsNil() {
        // python `parse()` не режет ```-обёртку — обёрнутый текст не валиден как JSON.
        XCTAssertNil(ActionItemsParser.parse("```json\n{\"action_items\": []}\n```"))
    }

    func testProseAroundJSONReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse("Вот ответ: {\"action_items\": []}"))
        XCTAssertNil(ActionItemsParser.parse("{\"action_items\": []}\nСпасибо!"))
    }

    func testExtraTopLevelKeyReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [], "note": "x"}"#))
    }

    func testWrongTopLevelKeyReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"items": []}"#))
    }

    func testTopLevelValueNotDictReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse("[1,2,3]"))
        XCTAssertNil(ActionItemsParser.parse("5"))
    }

    func testActionItemsNotListReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": {}}"#))
    }

    func testExtraItemKeyReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [{"assignee": "А", "task": "т", "due": null, "extra": 1}]}"#))
    }

    func testMissingItemKeyReturnsNil() {
        // python `run_checks` требует set(item) == {assignee, task, due} — отсутствие
        // ключа тоже нарушение схемы, не только лишний.
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [{"assignee": "А", "task": "т"}]}"#))
    }

    func testEmptyTaskReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [{"assignee": null, "task": "", "due": null}]}"#))
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [{"assignee": null, "task": "   ", "due": null}]}"#))
    }

    func testTaskAsNumberReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [{"assignee": null, "task": 5, "due": null}]}"#))
    }

    func testAssigneeAsNumberReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [{"assignee": 5, "task": "сделать", "due": null}]}"#))
    }

    func testDueAsBoolReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [{"assignee": null, "task": "сделать", "due": true}]}"#))
    }

    func testItemNotDictReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": ["не объект"]}"#))
    }

    func testCyrillicAndYo() {
        let items = ActionItemsParser.parse(#"{"action_items": [{"assignee": "Пётр", "task": "заплатить ёлку", "due": "сегодня"}]}"#)
        XCTAssertEqual(items, [ActionItem(assignee: "Пётр", task: "заплатить ёлку", due: "сегодня")])
    }

    func testWhitespaceAroundIsTrimmed() {
        XCTAssertEqual(ActionItemsParser.parse("  \n{\"action_items\": []}\n  "), [])
    }

    // MARK: - normalize

    func testNormalizeLowercasesCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(ActionItemsParser.normalize("  Собрать   Команду\tи\nОбсудить  "), "собрать команду и обсудить")
    }

    func testNormalizeDoesNotReplaceYo() {
        // Python `normalize()` не заменяет «ё» на «е» — только lower()+split.
        XCTAssertEqual(ActionItemsParser.normalize("Ёлка и Заяц"), "ёлка и заяц")
    }

    func testNormalizeNilReturnsEmptyString() {
        XCTAssertEqual(ActionItemsParser.normalize(nil), "")
    }

    // MARK: - Граничные случаи (задача 85, стадия тестирования)

    func testUnicodeEscapedCyrillicDecodesCorrectly() {
        // Аня == «Аня» — модель может отдать \u-escape вместо сырой
        // кириллицы (валидный JSON); JSONSerialization обязана раскрыть его до сравнения.
        let raw = "{\"action_items\": [{\"assignee\": \"\\u0410\\u043d\\u044f\", \"task\": \"сделать\", \"due\": null}]}"
        let items = ActionItemsParser.parse(raw)
        XCTAssertEqual(items, [ActionItem(assignee: "Аня", task: "сделать", due: nil)])
    }

    func testEmojiInTaskSurvivesRoundTrip() {
        let items = ActionItemsParser.parse(#"{"action_items": [{"assignee": null, "task": "отправить отчёт 🚀📎", "due": null}]}"#)
        XCTAssertEqual(items, [ActionItem(assignee: nil, task: "отправить отчёт 🚀📎", due: nil)])
    }

    func testVeryLongInputDoesNotCrashAndParsesCorrectly() {
        let longTask = String(repeating: "очень длинная задача ", count: 5000)
        let raw = #"{"action_items": [{"assignee": null, "task": ""# + longTask + #"", "due": null}]}"#
        let items = ActionItemsParser.parse(raw)
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(items?.first?.task, longTask)
    }

    func testTaskAsNestedObjectReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [{"assignee": null, "task": {"nested": "x"}, "due": null}]}"#))
    }

    func testDueAsNumberReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [{"assignee": null, "task": "сделать", "due": 5}]}"#))
    }

    func testAssigneeAsNestedObjectReturnsNil() {
        XCTAssertNil(ActionItemsParser.parse(#"{"action_items": [{"assignee": {"name": "Аня"}, "task": "сделать", "due": null}]}"#))
    }
}
