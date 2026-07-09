// IncrementalHighlightTextViewTests.swift — сквозная проверка инкрементального
// пути на реальном NSTextView: правка через textStorage → textDidChange даёт то
// же сокрытие, что полный highlight того же итогового текста; каретка не прыгает;
// устаревший кэш не роняет процесс (регрессия ConcealablesCrashRegressionTests
// расширена на инкрементальный путь).

import XCTest
import SwiftUI
@testable import SecondBrain

@MainActor
final class IncrementalHighlightTextViewTests: XCTestCase {

    private func makeCoordinator() -> (MarkdownEditorView.Coordinator, MarkdownTextView) {
        var boundText = ""
        let binding = Binding<String>(get: { boundText }, set: { boundText = $0 })
        let coordinator = MarkdownEditorView.Coordinator(text: binding, completionTargets: { [] }, onWikilinkClick: { _ in })
        let textView = MarkdownTextView()
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator      // запись правок для инкремента
        return (coordinator, textView)
    }

    /// Полный highlight того же текста с тем же курсором — эталон сокрытия.
    private func expectedConcealedRanges(for text: String, caret: NSRange) -> [NSRange] {
        let (coordinator, textView) = makeCoordinator()
        textView.textStorage?.setAttributedString(NSAttributedString(string: text))
        textView.setSelectedRange(caret)
        coordinator.highlight(textView)
        return coordinator.concealingDelegate.concealedRanges
    }

    func testIncrementalEditMatchesFullHighlight() {
        let (coordinator, textView) = makeCoordinator()
        let initial = "# Заголовок\n\nтекст [[Ссылка]] тут\n\n- пункт"
        textView.textStorage?.setAttributedString(NSAttributedString(string: initial))
        coordinator.highlight(textView)

        // Печатаем «**жирный**» в теле (после «тут»).
        let insertAt = (textView.string as NSString).range(of: "тут").location + 3
        let inserted = " **жирный**"
        textView.textStorage?.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: inserted)
        let caret = NSRange(location: insertAt + (inserted as NSString).length, length: 0)
        textView.setSelectedRange(caret)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        let expected = expectedConcealedRanges(for: textView.string, caret: caret)
        XCTAssertEqual(coordinator.concealingDelegate.concealedRanges, expected)
    }

    func testIncrementalDeleteMatchesFullHighlight() {
        let (coordinator, textView) = makeCoordinator()
        let initial = "текст **жирный** и [[Ссылка]]\n\nвторой абзац"
        textView.textStorage?.setAttributedString(NSAttributedString(string: initial))
        coordinator.highlight(textView)

        // Удаляем один «*» — bold ломается.
        let star = (textView.string as NSString).range(of: "**").location
        textView.textStorage?.replaceCharacters(in: NSRange(location: star, length: 1), with: "")
        let caret = NSRange(location: star, length: 0)
        textView.setSelectedRange(caret)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertEqual(coordinator.concealingDelegate.concealedRanges, expectedConcealedRanges(for: textView.string, caret: caret))
    }

    func testTypingFenceFallsBackAndMatchesFullHighlight() {
        let (coordinator, textView) = makeCoordinator()
        let initial = "текст\n\nещё текст"
        textView.textStorage?.setAttributedString(NSAttributedString(string: initial))
        coordinator.highlight(textView)

        // Вставляем код-фенс — структурная правка, должна уйти в полный проход.
        let insertAt = (textView.string as NSString).length
        let inserted = "\n\n```\nlet x = 1\n```"
        textView.textStorage?.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: inserted)
        let caret = NSRange(location: insertAt + (inserted as NSString).length, length: 0)
        textView.setSelectedRange(caret)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertEqual(coordinator.concealingDelegate.concealedRanges, expectedConcealedRanges(for: textView.string, caret: caret))
    }

    func testCaretDoesNotJumpOnIncrementalEdit() {
        let (coordinator, textView) = makeCoordinator()
        let initial = "# Заголовок\n\nтело [[Ссылка]] текст"
        textView.textStorage?.setAttributedString(NSAttributedString(string: initial))
        coordinator.highlight(textView)

        let insertAt = (textView.string as NSString).range(of: "тело").location + 4
        textView.textStorage?.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: "X")
        let caret = NSRange(location: insertAt + 1, length: 0)
        textView.setSelectedRange(caret)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertEqual(textView.selectedRange(), caret, "инкрементальная перекраска не должна двигать каретку")
    }

    func testStaleCacheOnIncrementalPathDoesNotCrash() {
        // Кэш от длинного текста, storage резко короче — bounds-guard'ы держат.
        let (coordinator, textView) = makeCoordinator()
        let longText = String(repeating: "# Заголовок с **жирным** [[Заметка]]\n\n", count: 20)
        textView.textStorage?.setAttributedString(NSAttributedString(string: longText))
        coordinator.highlight(textView)

        textView.string = "тук"    // подмена без обновления кэша
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        // Дошли до конца без краша.
        coordinator.textViewDidChangeSelection(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(textView.string, "тук")
    }
}
