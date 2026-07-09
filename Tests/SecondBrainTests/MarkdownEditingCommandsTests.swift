// MarkdownEditingCommandsTests.swift — чистая логика обсидиановских удобств:
// авто-продолжение списков по Enter и ⌘B/⌘I (обернуть/снять). Применение к
// NSTextView — в MarkdownTextView, здесь — только решения.

import XCTest
@testable import SecondBrain

final class MarkdownEditingCommandsTests: XCTestCase {

    private func newline(_ text: String, at caret: Int) -> MarkdownEditingCommands.NewlineResult? {
        MarkdownEditingCommands.newlineInsertion(in: text as NSString, selection: NSRange(location: caret, length: 0))
    }

    // MARK: - Авто-продолжение списков

    func testContinuesBulletList() {
        let text = "- пункт"
        let r = newline(text, at: (text as NSString).length)
        XCTAssertEqual(r?.replacement, "\n- ")
    }

    func testContinuesAsteriskAndPlusMarkers() {
        XCTAssertEqual(newline("* пункт", at: 7)?.replacement, "\n* ")
        XCTAssertEqual(newline("+ пункт", at: 7)?.replacement, "\n+ ")
    }

    func testIncrementsOrderedList() {
        let text = "3. третий"
        let r = newline(text, at: (text as NSString).length)
        XCTAssertEqual(r?.replacement, "\n4. ")
    }

    func testContinuesChecklistUnchecked() {
        let text = "- [ ] задача"
        let r = newline(text, at: (text as NSString).length)
        XCTAssertEqual(r?.replacement, "\n- [ ] ")
    }

    func testContinuesCheckedChecklistAsEmptyCheckbox() {
        let text = "- [x] сделано"
        let r = newline(text, at: (text as NSString).length)
        XCTAssertEqual(r?.replacement, "\n- [ ] ")
    }

    func testPreservesIndent() {
        let text = "    - вложенный"
        let r = newline(text, at: (text as NSString).length)
        XCTAssertEqual(r?.replacement, "\n    - ")
    }

    func testEmptyItemTerminatesList() {
        let text = "- "
        let r = newline(text, at: 2)
        XCTAssertEqual(r?.replacement, "")               // маркер убран
        XCTAssertEqual(r?.replaceRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(r?.cursor, 0)
    }

    func testEmptyCheckboxItemTerminates() {
        let text = "- [ ] "
        let r = newline(text, at: 6)
        XCTAssertEqual(r?.replacement, "")
    }

    func testNonListReturnsNil() {
        XCTAssertNil(newline("обычный текст", at: 5))
        XCTAssertNil(newline("# Заголовок", at: 5))
    }

    func testSelectionReturnsNil() {
        let r = MarkdownEditingCommands.newlineInsertion(in: "- пункт" as NSString, selection: NSRange(location: 0, length: 3))
        XCTAssertNil(r)
    }

    func testContinuationCursorLandsAfterPrefix() {
        let text = "- один"
        let r = newline(text, at: 6)
        XCTAssertEqual(r?.cursor, 6 + ("\n- " as NSString).length)
    }

    // MARK: - ⌘B/⌘I (wrapToggle)

    private func wrap(_ text: String, _ sel: NSRange, _ marker: String) -> MarkdownEditingCommands.WrapResult {
        MarkdownEditingCommands.wrapToggle(in: text as NSString, selection: sel, marker: marker)
    }

    func testWrapSelectionBold() {
        let r = wrap("жирный текст", NSRange(location: 0, length: 6), "**")
        XCTAssertEqual(r.replacement, "**жирный**")
        XCTAssertEqual(r.selection, NSRange(location: 2, length: 6))
    }

    func testUnwrapWhenMarkersInsideSelection() {
        let r = wrap("**жирный**", NSRange(location: 0, length: 10), "**")
        XCTAssertEqual(r.replacement, "жирный")
        XCTAssertEqual(r.selection, NSRange(location: 0, length: 6))
    }

    func testUnwrapWhenMarkersAroundSelection() {
        // Выделено «жирный» без «**», а маркеры сразу вокруг — снять их.
        let r = wrap("**жирный**", NSRange(location: 2, length: 6), "**")
        XCTAssertEqual(r.replacement, "жирный")
        XCTAssertEqual(r.range, NSRange(location: 0, length: 10))
        XCTAssertEqual(r.selection, NSRange(location: 0, length: 6))
    }

    func testWrapWithoutSelectionInsertsPairAndCentersCursor() {
        let r = wrap("", NSRange(location: 0, length: 0), "*")
        XCTAssertEqual(r.replacement, "**")
        XCTAssertEqual(r.selection, NSRange(location: 1, length: 0))
    }

    func testItalicMarker() {
        let r = wrap("курсив", NSRange(location: 0, length: 6), "*")
        XCTAssertEqual(r.replacement, "*курсив*")
    }

    // MARK: - wrapMarker

    func testWrapMarkerForTyped() {
        XCTAssertEqual(MarkdownEditingCommands.wrapMarker(forTyped: "*"), "*")
        XCTAssertEqual(MarkdownEditingCommands.wrapMarker(forTyped: "`"), "`")
        XCTAssertEqual(MarkdownEditingCommands.wrapMarker(forTyped: "_"), "_")
        XCTAssertNil(MarkdownEditingCommands.wrapMarker(forTyped: "a"))
        XCTAssertNil(MarkdownEditingCommands.wrapMarker(forTyped: "="))
    }
}
