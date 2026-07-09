// CursorScrollPreservationTests.swift — позиция курсора/прокрутки при внешней
// замене текста (MarkdownEditorView.Coordinator.reloadDisposition).
//
// Раньше любая внешняя замена (updateNSView) кидала курсор в начало и прокрутку
// наверх — раздражало при тихой перезагрузке того же файла с диска. Теперь:
// сменили файл → в начало; тот же файл → сохранить позицию (заклампив под длину).

import XCTest
@testable import SecondBrain

final class CursorScrollPreservationTests: XCTestCase {

    func testFileChangedResetsToTop() {
        let d = MarkdownEditorView.Coordinator.reloadDisposition(fileChanged: true, savedCaret: NSRange(location: 42, length: 3), newLength: 100)
        XCTAssertEqual(d.caret, NSRange(location: 0, length: 0))
        XCTAssertTrue(d.resetScroll)
    }

    func testSameFilePreservesCaretAndScroll() {
        let d = MarkdownEditorView.Coordinator.reloadDisposition(fileChanged: false, savedCaret: NSRange(location: 10, length: 0), newLength: 100)
        XCTAssertEqual(d.caret, NSRange(location: 10, length: 0))
        XCTAssertFalse(d.resetScroll)
    }

    func testCaretBeyondNewLengthIsClamped() {
        // Внешняя версия короче — курсор за пределом заклампится в конец.
        let d = MarkdownEditorView.Coordinator.reloadDisposition(fileChanged: false, savedCaret: NSRange(location: 200, length: 5), newLength: 100)
        XCTAssertEqual(d.caret, NSRange(location: 100, length: 0))
        XCTAssertFalse(d.resetScroll)
    }

    func testSelectionClampedToRemainingLength() {
        let d = MarkdownEditorView.Coordinator.reloadDisposition(fileChanged: false, savedCaret: NSRange(location: 98, length: 10), newLength: 100)
        XCTAssertEqual(d.caret.location, 98)
        XCTAssertLessThanOrEqual(NSMaxRange(d.caret), 100)
    }
}
