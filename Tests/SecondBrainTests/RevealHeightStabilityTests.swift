// RevealHeightStabilityTests.swift — раскрытие маркеров НЕ меняет высоту строки.
//
// Регрессия на «какая-то строчка съезжает при каждом клике»: с .null-глифами
// ведущие скрытые маркеры абзаца (#, «- ») пришивались к предыдущему фрагменту
// и верстальщик терял paragraphSpacingBefore — строка меняла высоту при
// раскрытии. Теперь сокрытие = .controlCharacter + .zeroAdvancement (глиф
// остаётся в своей строке), высота строки обязана быть одинаковой при скрытых
// и показанных маркерах — меняться может только ширина.

import XCTest
import SwiftUI
@testable import SecondBrain

@MainActor
final class RevealHeightStabilityTests: XCTestCase {

    /// Общая проверка: высота документа с курсором на строке-носителе маркера
    /// равна высоте с курсором вне её.
    private func assertStableHeight(_ text: String, caretInside: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        var boundText = ""
        let binding = Binding<String>(get: { boundText }, set: { boundText = $0 })
        let coordinator = MarkdownEditorView.Coordinator(text: binding, completionTargets: { [] }, onWikilinkClick: { _ in })
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        textView.layoutManager?.delegate = coordinator.concealingDelegate
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.textStorage?.setAttributedString(NSAttributedString(string: text))
        coordinator.highlight(textView)
        let lm = textView.layoutManager!
        let tc = textView.textContainer!
        let caretLoc = (text as NSString).range(of: caretInside).location

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        lm.ensureLayout(for: tc)
        let concealedHeight = lm.usedRect(for: tc).height

        textView.setSelectedRange(NSRange(location: caretLoc, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        lm.ensureLayout(for: tc)
        let revealedHeight = lm.usedRect(for: tc).height

        XCTAssertEqual(revealedHeight, concealedHeight, accuracy: 0.001,
                       "раскрытие маркера изменило высоту документа (строка «съезжает»)",
                       file: file, line: line)
    }

    func testHeading1LineHeightStable() {
        assertStableHeight("абзац\n\n# Заголовок раз\n\nхвост текста", caretInside: "Заголовок раз")
    }

    func testHeading3LineHeightStable() {
        assertStableHeight("абзац\n\n### Заголовок три\n\nхвост текста", caretInside: "Заголовок три")
    }

    func testListLineHeightStable() {
        assertStableHeight("абзац\n\n- пункт списка\n\nхвост текста", caretInside: "пункт списка")
    }

    func testNestedListLineHeightStable() {
        assertStableHeight("абзац\n\n- верхний\n  - вложенный\n\nхвост", caretInside: "вложенный")
    }

    func testBoldLineHeightStable() {
        assertStableHeight("абзац\n\nтело **жирное** тут\n\nхвост", caretInside: "жирное")
    }

    func testBlockquoteLineHeightStable() {
        assertStableHeight("абзац\n\n> цитата тут\n\nхвост", caretInside: "цитата")
    }

    func testChecklistLineHeightStable() {
        assertStableHeight("абзац\n\n- [ ] задача\n\nхвост", caretInside: "задача")
    }

    func testWikilinkLineHeightStable() {
        assertStableHeight("абзац\n\nтекст [[Ссылка]] тут\n\nхвост", caretInside: "Ссылка")
    }
}
