// ConcealmentGeometryTests.swift — детерминированная геометрия сокрытия.
//
// Регрессия на «строчка съезжает при клике и не возвращается»: высоты строк
// теперь управляются явно (fullyConcealedLines → схлопнутые фрагменты в
// ConcealingLayoutDelegate.shouldSetLineFragmentRect), \n никогда не
// нуллифицируется, при смене раскрытого набора раскладка пересчитывается
// целиком. Ключевой тест — цикл раскрыть/скрыть возвращает В ТОЧНОСТИ
// исходную высоту документа, сколько бы раз ни повторялся.

import XCTest
import SwiftUI
@testable import SecondBrain

final class ConcealmentGeometryTests: XCTestCase {

    // MARK: - fullyConcealedLines (чистая логика)

    /// Полный набор маркеров текста + слитые скрытые диапазоны при данном
    /// множестве раскрытых.
    private func markersAndConcealed(_ text: String, revealed: Set<Int> = []) -> ([ConcealableMarker], [NSRange]) {
        let ns = text as NSString
        var markers: [ConcealableMarker] = []
        markers += CommentBlockParser.parse(text).map { ConcealableMarker.forCommentBlock($0, in: ns) }
        markers += MarkdownHighlighter.matches(in: text).flatMap { ConcealableMarker.forHighlighterMatch($0, in: ns) }
        markers += ConcealableMarker.forListMarkers(in: text)
        let concealed = MarkdownEditorView.Coordinator.concealedRanges(from: markers, revealed: revealed, storageLength: ns.length)
        return (markers, concealed)
    }

    func testFenceLinesAreFullyConcealedWhenNotRevealed() {
        let text = "```swift\nlet a = 1\n```"
        let ns = text as NSString
        let (markers, concealed) = markersAndConcealed(text)
        let lines = MarkdownEditorView.Coordinator.fullyConcealedLines(in: ns, markers: markers, revealed: [], concealed: concealed)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(ns.substring(with: lines[0]), "```swift\n")
        XCTAssertEqual(ns.substring(with: lines[1]), "```")
    }

    func testFenceLinesNotCollapsedWhenRevealed() {
        let text = "```swift\nlet a = 1\n```"
        let ns = text as NSString
        let (markers, _) = markersAndConcealed(text)
        // Раскрываем все маркеры — скрытых диапазонов нет, схлопнутых строк нет.
        let all = Set(markers.indices)
        let concealed = MarkdownEditorView.Coordinator.concealedRanges(from: markers, revealed: all, storageLength: ns.length)
        let lines = MarkdownEditorView.Coordinator.fullyConcealedLines(in: ns, markers: markers, revealed: all, concealed: concealed)
        XCTAssertTrue(lines.isEmpty)
    }

    func testInlineCommentLineWithVisibleTextIsNotCollapsed() {
        // «текст %%скрыто%% хвост» — контент строки скрыт не целиком.
        let text = "текст %%скрыто%% хвост"
        let ns = text as NSString
        let (markers, concealed) = markersAndConcealed(text)
        let lines = MarkdownEditorView.Coordinator.fullyConcealedLines(in: ns, markers: markers, revealed: [], concealed: concealed)
        XCTAssertTrue(lines.isEmpty)
    }

    func testMultilineCommentLinesAreCollapsed() {
        let text = "до\n%% раз\nдва %%\nпосле"
        let ns = text as NSString
        let (markers, concealed) = markersAndConcealed(text)
        let lines = MarkdownEditorView.Coordinator.fullyConcealedLines(in: ns, markers: markers, revealed: [], concealed: concealed)
        XCTAssertEqual(lines.map { ns.substring(with: $0) }, ["%% раз\n", "два %%\n"])
    }

    func testHeadingAndListLinesAreNeverCollapsed() {
        // Маркеры «#» и «- » скрыты, но текст строк виден — строки не схлопываются.
        let text = "# Заголовок\n- пункт списка"
        let ns = text as NSString
        let (markers, concealed) = markersAndConcealed(text)
        let lines = MarkdownEditorView.Coordinator.fullyConcealedLines(in: ns, markers: markers, revealed: [], concealed: concealed)
        XCTAssertTrue(lines.isEmpty)
    }

    // MARK: - Детерминизм раскладки на реальном NSTextView (регрессия «съезжает»)

    @MainActor
    private func makeEditor(_ text: String) -> (MarkdownEditorView.Coordinator, MarkdownTextView, NSLayoutManager, NSTextContainer) {
        var boundText = ""
        let binding = Binding<String>(get: { boundText }, set: { boundText = $0 })
        let coordinator = MarkdownEditorView.Coordinator(text: binding, completionTargets: { [] }, onWikilinkClick: { _ in })
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        textView.layoutManager?.delegate = coordinator.concealingDelegate
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.textStorage?.setAttributedString(NSAttributedString(string: text))
        coordinator.highlight(textView)
        return (coordinator, textView, textView.layoutManager!, textView.textContainer!)
    }

    @MainActor
    func testRevealConcealCyclesRestoreExactDocumentHeight() {
        let text = "# Заголовок\n\nтекст перед блоком\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nтекст после блока\nещё строка"
        let (coordinator, textView, layoutManager, container) = makeEditor(text)
        let ns = text as NSString

        layoutManager.ensureLayout(for: container)
        let collapsedHeight = layoutManager.usedRect(for: container).height

        let insideBlock = ns.range(of: "let a").location
        let outsideBlock = ns.range(of: "текст перед").location

        for cycle in 1...5 {
            // Курсор внутрь код-блока — фенсы раскрываются, документ выше.
            textView.setSelectedRange(NSRange(location: insideBlock, length: 0))
            coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
            layoutManager.ensureLayout(for: container)
            let revealedHeight = layoutManager.usedRect(for: container).height
            XCTAssertGreaterThan(revealedHeight, collapsedHeight, "цикл \(cycle): раскрытие должно увеличить высоту")

            // Курсор наружу — высота обязана вернуться В ТОЧНОСТИ (не «почти»).
            textView.setSelectedRange(NSRange(location: outsideBlock, length: 0))
            coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
            layoutManager.ensureLayout(for: container)
            let restoredHeight = layoutManager.usedRect(for: container).height
            XCTAssertEqual(restoredHeight, collapsedHeight, accuracy: 0.001,
                           "цикл \(cycle): высота не вернулась (дрейф раскладки)")
        }
    }

    @MainActor
    func testCursorTravelAcrossManyLinesKeepsHeightStable() {
        // Прогулка курсором по всем строкам (заголовки/списки/жирный/ссылки) и
        // возврат — высота как в исходном состоянии, ничего не «уезжает».
        let text = "# Раз\n\n- пункт **жирный**\n- ещё [[Ссылка]]\n\n## Два\n\nобычный текст `код`\n\n> цитата"
        let (coordinator, textView, layoutManager, container) = makeEditor(text)
        let ns = text as NSString

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        layoutManager.ensureLayout(for: container)
        let baseline = layoutManager.usedRect(for: container).height

        var location = 0
        while location < ns.length {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
            location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        layoutManager.ensureLayout(for: container)

        XCTAssertEqual(layoutManager.usedRect(for: container).height, baseline, accuracy: 0.001,
                       "высота уехала после прогулки курсором")
    }
}
