// NoteTemplateTests.swift — подстановка плейсхолдеров шаблона заметки (задача 79).

import XCTest
@testable import SecondBrain

final class NoteTemplateTests: XCTestCase {

    func testRenderSubstitutesDateAndTitle() {
        let moscow = TimeZone(identifier: "Europe/Moscow")!
        let date = Date(timeIntervalSince1970: 1_784_548_800) // 2026-07-20 12:00 UTC = 15:00 МСК
        let out = NoteTemplate.render("# {{title}}\nДата: {{date}}",
                                      title: "Заметка",
                                      date: date, timeZone: moscow)
        XCTAssertEqual(out, "# Заметка\nДата: 2026-07-20")
    }

    func testRenderUnknownPlaceholderStaysAsIs() {
        let out = NoteTemplate.render("{{Date}} и {{title}}", title: "X")
        XCTAssertEqual(out, "{{Date}} и X", "опечатка в плейсхолдере — не угадываем намерение")
    }

    func testRenderEmptyTemplate() {
        XCTAssertEqual(NoteTemplate.render("", title: "X"), "")
    }

    func testRenderTemplateWithoutPlaceholders() {
        XCTAssertEqual(NoteTemplate.render("Обычный текст без плейсхолдеров", title: "X"),
                       "Обычный текст без плейсхолдеров")
    }

    func testRenderRepeatedTitlePlaceholder() {
        let out = NoteTemplate.render("{{title}} / {{title}}", title: "Встреча")
        XCTAssertEqual(out, "Встреча / Встреча")
    }

    func testRenderDateCrossesMidnightByTimeZone() {
        let utc = TimeZone(identifier: "UTC")!
        let moscow = TimeZone(identifier: "Europe/Moscow")!
        let date = Date(timeIntervalSince1970: 1_767_309_000) // 2026-01-01 23:10 UTC
        XCTAssertEqual(NoteTemplate.render("{{date}}", title: "X", date: date, timeZone: utc), "2026-01-01")
        XCTAssertEqual(NoteTemplate.render("{{date}}", title: "X", date: date, timeZone: moscow), "2026-01-02")
    }
}
