// StructuralEditDetectionTests.swift — когда инкрементальной подсветки НЕ хватает.
//
// Код-фенсы ``` и %%-комментарии многоблочны: их правка перекрашивает всё после
// них, поэтому уходит в полный проход (needsFullRehighlight). Обычная разметка —
// инкрементально. Проверяем чистое правило (static needsFullRehighlight).

import XCTest
@testable import SecondBrain

final class StructuralEditDetectionTests: XCTestCase {

    private func needsFull(blockText: String, oldDirty: NSRange = NSRange(location: 0, length: 0), markers: [ConcealableMarker] = []) -> Bool {
        MarkdownEditorView.Coordinator.needsFullRehighlight(newBlockText: blockText, oldDirty: oldDirty, markers: markers)
    }

    func testTypingFenceLineIsStructural() {
        XCTAssertTrue(needsFull(blockText: "```swift"))
        XCTAssertTrue(needsFull(blockText: "текст\n```\nкод"))
    }

    func testTypingCommentMarkerIsStructural() {
        XCTAssertTrue(needsFull(blockText: "заметка %% скрытое"))
        XCTAssertTrue(needsFull(blockText: "%%"))
    }

    func testEditingInsideExistingFenceIsStructural() {
        // Существующий код-блок как маркер .codeBlock на [0,30); правка внутри.
        let fence = ConcealableMarker(hideRanges: [NSRange(location: 0, length: 4)], revealTrigger: NSRange(location: 0, length: 30), revealStyle: .codeBlock)
        XCTAssertTrue(needsFull(blockText: "let x = 1", oldDirty: NSRange(location: 10, length: 1), markers: [fence]))
    }

    func testDeletingAcrossFenceBoundaryIsStructural() {
        let fence = ConcealableMarker(hideRanges: [NSRange(location: 0, length: 4)], revealTrigger: NSRange(location: 0, length: 30), revealStyle: .codeBlock)
        // Удаление-выделение [25,10) пересекает конец фенса.
        XCTAssertTrue(needsFull(blockText: "хвост", oldDirty: NSRange(location: 25, length: 10), markers: [fence]))
    }

    func testOrdinaryEditsAreNotStructural() {
        XCTAssertFalse(needsFull(blockText: "# Заголовок и **жирный**"))
        XCTAssertFalse(needsFull(blockText: "текст [[Ссылка]] и ==выделение=="))
        XCTAssertFalse(needsFull(blockText: "- пункт списка"))
        // .codeBlock-маркер есть, но далеко от правки — не структурно.
        let farFence = ConcealableMarker(hideRanges: [NSRange(location: 0, length: 4)], revealTrigger: NSRange(location: 0, length: 10), revealStyle: .codeBlock)
        XCTAssertFalse(needsFull(blockText: "обычный текст", oldDirty: NSRange(location: 50, length: 2), markers: [farFence]))
    }
}
