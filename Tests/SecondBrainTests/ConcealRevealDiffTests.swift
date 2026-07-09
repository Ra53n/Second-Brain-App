// ConcealRevealDiffTests.swift — угловые кейсы решающей логики Live Preview:
// какие маркеры развёрнуты при данной позиции курсора (MarkdownEditorView.
// Coordinator.revealedIndices).
//
// Именно этот дифф чинит «бросает наверх заметки»: на смену курсора storage
// трогается ТОЛЬКО для маркеров, чьё множество изменилось. Ключевые гарантии,
// которые тут проверяются: движение в пределах строки НЕ меняет множество
// (значит, никаких правок storage и сброса прокрутки), переход на другую строку
// меняет, устаревшие (вне границ) маркеры исключаются (защита от краша).

import XCTest
@testable import SecondBrain

final class ConcealRevealDiffTests: XCTestCase {

    private func marker(trigger: NSRange, hide: NSRange) -> ConcealableMarker {
        ConcealableMarker(hideRanges: [hide], revealTrigger: trigger, revealStyle: .plain, concealedFontSize: 5)
    }

    // MARK: - Строки и переходы

    func testCaretOnLineRevealsOnlyThatLinesMarkers() {
        // Две «строки»: [0,10) и [10,20). Маркеры-триггеры на каждой.
        let markers = [
            marker(trigger: NSRange(location: 0, length: 10), hide: NSRange(location: 0, length: 1)),
            marker(trigger: NSRange(location: 10, length: 10), hide: NSRange(location: 10, length: 1))
        ]
        let onFirst = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 3, length: 0), in: markers, storageLength: 20)
        XCTAssertEqual(onFirst, [0])

        let onSecond = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 14, length: 0), in: markers, storageLength: 20)
        XCTAssertEqual(onSecond, [1])
    }

    func testMovingCaretWithinSameLineDoesNotChangeSet() {
        // Гарантия no-op: курсор в разных местах ОДНОЙ строки → одно множество.
        let markers = [marker(trigger: NSRange(location: 0, length: 10), hide: NSRange(location: 0, length: 1))]
        let a = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 2, length: 0), in: markers, storageLength: 10)
        let b = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 7, length: 0), in: markers, storageLength: 10)
        XCTAssertEqual(a, b)
    }

    func testCaretOnPlainLineRevealsNothing() {
        let markers = [marker(trigger: NSRange(location: 0, length: 5), hide: NSRange(location: 0, length: 1))]
        // Курсор на «строке» без маркеров (10..15) — пустое множество.
        let result = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 12, length: 0), in: markers, storageLength: 20)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Несколько маркеров на одной строке

    func testMultipleMarkersOnSameLineRevealTogether() {
        let markers = [
            marker(trigger: NSRange(location: 0, length: 20), hide: NSRange(location: 0, length: 1)),
            marker(trigger: NSRange(location: 0, length: 20), hide: NSRange(location: 5, length: 2)),
            marker(trigger: NSRange(location: 0, length: 20), hide: NSRange(location: 10, length: 2))
        ]
        let result = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 8, length: 0), in: markers, storageLength: 20)
        XCTAssertEqual(result, [0, 1, 2])
    }

    // MARK: - Границы курсора

    func testCaretExactlyAtEndOfTriggerReveals() {
        // Блок-ссылка в конце строки: курсор сразу за ней (на правой границе).
        let markers = [marker(trigger: NSRange(location: 0, length: 10), hide: NSRange(location: 6, length: 4))]
        let result = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 10, length: 0), in: markers, storageLength: 10)
        XCTAssertEqual(result, [0])
    }

    func testSelectionSpanningTwoLinesRevealsBoth() {
        let markers = [
            marker(trigger: NSRange(location: 0, length: 10), hide: NSRange(location: 0, length: 1)),
            marker(trigger: NSRange(location: 10, length: 10), hide: NSRange(location: 10, length: 1))
        ]
        // Выделение [5,10) захватывает конец первой и начало второй строки.
        let result = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 5, length: 10), in: markers, storageLength: 20)
        XCTAssertEqual(result, [0, 1])
    }

    // MARK: - Устаревший кэш (защита от краша)

    func testStaleMarkersBeyondStorageAreExcluded() {
        // Кэш от длинного текста, storage теперь короткий (5). Маркеры за
        // границей не попадают в множество → styleMarker их не тронет.
        let markers = [
            marker(trigger: NSRange(location: 0, length: 3), hide: NSRange(location: 0, length: 1)),
            marker(trigger: NSRange(location: 40, length: 6), hide: NSRange(location: 40, length: 2))
        ]
        let result = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 1, length: 0), in: markers, storageLength: 5)
        XCTAssertEqual(result, [0])
    }

    func testHideRangeBeyondStorageExcludesMarkerEvenIfTriggerFits() {
        // Триггер в пределах, а один hideRange вылез за границу (частичная
        // рассинхронизация) — маркер целиком исключается, чтобы не упасть.
        let markers = [ConcealableMarker(
            hideRanges: [NSRange(location: 0, length: 1), NSRange(location: 9, length: 2)],
            revealTrigger: NSRange(location: 0, length: 3),
            revealStyle: .plain,
            concealedFontSize: 5
        )]
        let result = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 1, length: 0), in: markers, storageLength: 5)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Вырожденные входы

    func testEmptyMarkersGiveEmptySet() {
        XCTAssertTrue(MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 0, length: 0), in: [], storageLength: 0).isEmpty)
    }

    // MARK: - Реальный текст через фабрики

    func testRealHeadingLineDiffersFromBodyLine() {
        let text = "# Заголовок\n\nобычный текст без разметки"
        let ns = text as NSString
        let markers = MarkdownHighlighter.matches(in: text).flatMap { ConcealableMarker.forHighlighterMatch($0, in: ns) }
        XCTAssertFalse(markers.isEmpty)

        let onHeading = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: 2, length: 0), in: markers, storageLength: ns.length)
        let onBody = MarkdownEditorView.Coordinator.revealedIndices(for: NSRange(location: ns.length - 1, length: 0), in: markers, storageLength: ns.length)

        XCTAssertFalse(onHeading.isEmpty)   // на строке заголовка «#» развёрнут
        XCTAssertTrue(onBody.isEmpty)       // в обычном тексте разметки нет
        XCTAssertNotEqual(onHeading, onBody)
    }
}
