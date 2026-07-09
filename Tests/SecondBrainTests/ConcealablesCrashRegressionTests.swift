// ConcealablesCrashRegressionTests.swift — регрессия на крэш в styleConcealables.
//
// Живой краш (SecondBrain-2026-07-09-224724.ips): исключение в
// NSMutableAttributedString.addAttribute(_:value:range:) внутри
// Coordinator.styleConcealables, вызванного из textViewDidChangeSelection.
//
// Причина: смена textView.string (переключение файла в updateNSView,
// toggleChecklistMarker) синхронно шлёт NSTextViewDidChangeSelectionNotification
// ИЗНУТРИ присваивания .string — до того как highlight() успевает переразобрать
// новый текст и обновить currentConcealables. В этот момент currentConcealables
// ещё держит диапазоны от ПРЕДЫДУЩЕГО (обычно более длинного) текста, а
// storage уже отражает новый (короче) — addAttribute на диапазоне за пределами
// текущей длины кидает NSException. Исправлено проверкой границ в
// styleConcealables; здесь — тест, что сценарий гонки больше не роняет процесс.

import XCTest
import SwiftUI
@testable import SecondBrain

@MainActor
final class ConcealablesCrashRegressionTests: XCTestCase {

    func testSelectionChangeAfterTextShrinksDoesNotCrash() {
        var boundText = ""
        let binding = Binding<String>(get: { boundText }, set: { boundText = $0 })
        let coordinator = MarkdownEditorView.Coordinator(text: binding, completionTargets: { [] }, onWikilinkClick: { _ in })

        let textView = MarkdownTextView()
        textView.delegate = coordinator

        // Длинный текст с разметкой — currentConcealables заполнится диапазонами
        // относительно НЕГО (заголовки/жирный/wikilink на каждой из 20 строк).
        let longText = String(repeating: "# Заголовок с **жирным** и ссылкой [[Заметка]]\n", count: 20)
        textView.string = longText
        coordinator.highlight(textView)

        // Симулируем гонку: текст уже заменён на короткий (как в updateNSView
        // при смене файла), но кэш ещё не успел обновиться на момент реакции
        // на смену выделения.
        textView.string = "тут"

        // Раньше здесь падало (addAttribute вне границ storage). Дошли до
        // конца теста — значит, не упало.
        coordinator.textViewDidChangeSelection(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertEqual(textView.string, "тут")
    }

    func testSelectionChangeAfterTextGrowsDoesNotCrash() {
        // Симметричный случай: старый (короткий) кэш, новый текст ДЛИННЕЕ —
        // не должно быть проблем (диапазоны кэша заведомо укладываются), но
        // проверяем явно на случай будущих регрессий в логике границ.
        var boundText = ""
        let binding = Binding<String>(get: { boundText }, set: { boundText = $0 })
        let coordinator = MarkdownEditorView.Coordinator(text: binding, completionTargets: { [] }, onWikilinkClick: { _ in })

        let textView = MarkdownTextView()
        textView.delegate = coordinator

        textView.string = "# Раз"
        coordinator.highlight(textView)

        textView.string = String(repeating: "# Заголовок с **жирным**\n", count: 20)
        coordinator.textViewDidChangeSelection(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertTrue(textView.string.hasPrefix("# Заголовок"))
    }
}
