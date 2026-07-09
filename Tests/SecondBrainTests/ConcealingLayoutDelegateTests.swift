// ConcealingLayoutDelegateTests.swift — чистая логика сокрытия глифов.
//
// Сам факт «глиф не нарисовался» — UI-слой (не тестируется по CONVENTIONS.md),
// но вся арифметика вокруг — тестируема и критична: слияние диапазонов
// (предусловие бинарного поиска), проверка вхождения символа, сбор скрытых
// диапазонов из невыделенных маркеров.

import XCTest
@testable import SecondBrain

final class ConcealingLayoutDelegateTests: XCTestCase {

    // MARK: - mergeRanges

    func testMergeSortsByLocation() {
        let merged = ConcealingLayoutDelegate.mergeRanges([
            NSRange(location: 10, length: 2),
            NSRange(location: 0, length: 2)
        ])
        XCTAssertEqual(merged, [NSRange(location: 0, length: 2), NSRange(location: 10, length: 2)])
    }

    func testMergeCombinesOverlapping() {
        let merged = ConcealingLayoutDelegate.mergeRanges([
            NSRange(location: 0, length: 5),
            NSRange(location: 3, length: 5)
        ])
        XCTAssertEqual(merged, [NSRange(location: 0, length: 8)])
    }

    func testMergeCombinesAdjacent() {
        // Смежные (конец одного = начало другого) сливаются — иначе бинарный
        // поиск мог бы «провалиться» между ними на границе.
        let merged = ConcealingLayoutDelegate.mergeRanges([
            NSRange(location: 0, length: 3),
            NSRange(location: 3, length: 3)
        ])
        XCTAssertEqual(merged, [NSRange(location: 0, length: 6)])
    }

    func testMergeKeepsDisjoint() {
        let merged = ConcealingLayoutDelegate.mergeRanges([
            NSRange(location: 0, length: 2),
            NSRange(location: 5, length: 2)
        ])
        XCTAssertEqual(merged, [NSRange(location: 0, length: 2), NSRange(location: 5, length: 2)])
    }

    func testMergeDropsEmptyRanges() {
        let merged = ConcealingLayoutDelegate.mergeRanges([
            NSRange(location: 3, length: 0),
            NSRange(location: 5, length: 2)
        ])
        XCTAssertEqual(merged, [NSRange(location: 5, length: 2)])
    }

    func testMergeEmptyInput() {
        XCTAssertTrue(ConcealingLayoutDelegate.mergeRanges([]).isEmpty)
    }

    // MARK: - isConcealed (бинарный поиск)

    func testIsConcealedInsideRange() {
        let delegate = ConcealingLayoutDelegate()
        delegate.concealedRanges = [NSRange(location: 2, length: 3)] // [2,5)
        XCTAssertFalse(delegate.isConcealed(1))
        XCTAssertTrue(delegate.isConcealed(2))
        XCTAssertTrue(delegate.isConcealed(4))
        XCTAssertFalse(delegate.isConcealed(5)) // правая граница исключительна
    }

    func testIsConcealedAcrossManyRanges() {
        let delegate = ConcealingLayoutDelegate()
        delegate.concealedRanges = [
            NSRange(location: 0, length: 2),
            NSRange(location: 10, length: 2),
            NSRange(location: 20, length: 2),
            NSRange(location: 30, length: 2)
        ]
        XCTAssertTrue(delegate.isConcealed(0))
        XCTAssertTrue(delegate.isConcealed(11))
        XCTAssertTrue(delegate.isConcealed(31))
        XCTAssertFalse(delegate.isConcealed(5))
        XCTAssertFalse(delegate.isConcealed(15))
        XCTAssertFalse(delegate.isConcealed(100))
    }

    func testIsConcealedEmptyRanges() {
        let delegate = ConcealingLayoutDelegate()
        XCTAssertFalse(delegate.isConcealed(0))
        XCTAssertFalse(delegate.isConcealed(42))
    }

    // MARK: - concealedRanges (сбор из невыделенных маркеров)

    private func marker(trigger: NSRange, hide: [NSRange]) -> ConcealableMarker {
        ConcealableMarker(hideRanges: hide, revealTrigger: trigger, revealStyle: .plain)
    }

    func testConcealedRangesExcludesRevealedMarkers() {
        let markers = [
            marker(trigger: NSRange(location: 0, length: 10), hide: [NSRange(location: 0, length: 2)]),
            marker(trigger: NSRange(location: 10, length: 10), hide: [NSRange(location: 10, length: 2)])
        ]
        // Показан только маркер 0 → скрыт только маркер 1.
        let ranges = MarkdownEditorView.Coordinator.concealedRanges(from: markers, revealed: [0], storageLength: 20)
        XCTAssertEqual(ranges, [NSRange(location: 10, length: 2)])
    }

    func testConcealedRangesAllConcealedWhenNoneRevealed() {
        let markers = [
            marker(trigger: NSRange(location: 0, length: 10), hide: [NSRange(location: 0, length: 2)]),
            marker(trigger: NSRange(location: 10, length: 10), hide: [NSRange(location: 10, length: 2)])
        ]
        let ranges = MarkdownEditorView.Coordinator.concealedRanges(from: markers, revealed: [], storageLength: 20)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 2), NSRange(location: 10, length: 2)])
    }

    func testConcealedRangesMergesAndSorts() {
        // Маркер с двумя hideRanges (напр. wikilink: префикс+суффикс) + другой,
        // пришедший «не по порядку» — результат отсортирован и слит.
        let markers = [
            marker(trigger: NSRange(location: 20, length: 5), hide: [NSRange(location: 20, length: 2)]),
            marker(trigger: NSRange(location: 0, length: 10), hide: [NSRange(location: 0, length: 2), NSRange(location: 2, length: 3)])
        ]
        let ranges = MarkdownEditorView.Coordinator.concealedRanges(from: markers, revealed: [], storageLength: 30)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 5), NSRange(location: 20, length: 2)])
    }

    func testConcealedRangesExcludesOutOfBounds() {
        // Устаревший маркер за границей текста не попадает в скрытые (иначе
        // делегат нуллифицировал бы несуществующие глифы).
        let markers = [
            marker(trigger: NSRange(location: 0, length: 3), hide: [NSRange(location: 0, length: 2)]),
            marker(trigger: NSRange(location: 40, length: 6), hide: [NSRange(location: 40, length: 2)])
        ]
        let ranges = MarkdownEditorView.Coordinator.concealedRanges(from: markers, revealed: [], storageLength: 5)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 2)])
    }

    func testConcealedRangesEmptyMarkers() {
        XCTAssertTrue(MarkdownEditorView.Coordinator.concealedRanges(from: [], revealed: [], storageLength: 0).isEmpty)
    }
}
