// EditorTests.swift — тесты EditorViewModel и conflict-копий (задача 03).
//
// Покрытие:
//  - загрузка/переключение файлов, сохранение при переключении;
//  - debounce-автосохранение (короткий интервал вместо инжектируемых часов —
//    поведение то же, ожидание в тестах миллисекунды);
//  - внешнее изменение: тихое перечитывание без правок, конфликт с правками,
//    оба исхода конфликта;
//  - writeConflictCopy: суффикс «(conflict)», уникальность, оригинал не тронут;
//  - MarkdownHighlighter: диапазоны заголовков/жирного/кода;
//  - ChecklistParser: разбор `- [ ]`/`- [x]`, переключение маркера в NSTextStorage.

import XCTest
@testable import SecondBrain

@MainActor
final class EditorViewModelTests: VaultTestCase {

    /// VM с коротким debounce, чтобы тесты не ждали по полсекунды.
    private func makeVM() -> EditorViewModel {
        EditorViewModel(debounceMilliseconds: 40)
    }

    /// Ждём срабатывания debounce-автосохранения (40 мс + запас).
    private func waitForAutosave() {
        let waited = expectation(description: "debounce прошёл")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waited.fulfill() }
        wait(for: [waited], timeout: 1.0)
    }

    func testOpenLoadsContent() throws {
        let url = try makeFile("заметка.md", contents: "# Привет\n\nтекст")
        let vm = makeVM()

        vm.open(url)

        XCTAssertEqual(vm.text, "# Привет\n\nтекст")
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testDebouncedAutosaveWritesToDisk() throws {
        let url = try makeFile("заметка.md", contents: "старое")
        let vm = makeVM()
        vm.open(url)

        vm.text = "новое содержимое"
        // Сразу после правки на диске ещё старое (debounce не истёк).
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "старое")

        waitForAutosave()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "новое содержимое")
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testSwitchingFilesSavesPrevious() throws {
        let first = try makeFile("первая.md", contents: "1")
        let second = try makeFile("вторая.md", contents: "2")
        let vm = makeVM()

        vm.open(first)
        vm.text = "1 правка"
        vm.open(second) // переключение до истечения debounce

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "1 правка")
        XCTAssertEqual(vm.text, "2")
    }

    func testSaveNowIsIdempotentWithoutChanges() throws {
        let url = try makeFile("заметка.md", contents: "текст")
        let attrsBefore = try FileManager.default.attributesOfItem(atPath: url.path)
        let vm = makeVM()
        vm.open(url)

        vm.saveNow() // правок нет — записи быть не должно

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(
            attrsBefore[.modificationDate] as? Date,
            attrsAfter[.modificationDate] as? Date
        )
    }

    func testExternalChangeWithoutLocalEditsReloadsSilently() throws {
        let url = try makeFile("заметка.md", contents: "версия 1")
        let vm = makeVM()
        vm.open(url)

        // Внешний редактор перезаписал файл.
        try "версия 2 (извне)".write(to: url, atomically: true, encoding: .utf8)
        vm.checkExternalChange()

        XCTAssertEqual(vm.text, "версия 2 (извне)")
        XCTAssertNil(vm.conflict)
        // Перечитанное не считается правкой — debounce не перезапишет диск.
        waitForAutosave()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "версия 2 (извне)")
    }

    func testExternalChangeWithLocalEditsRaisesConflict() throws {
        let url = try makeFile("заметка.md", contents: "база")
        let vm = makeVM()
        vm.open(url)
        vm.text = "мои правки"

        try "внешняя версия".write(to: url, atomically: true, encoding: .utf8)
        vm.checkExternalChange()

        XCTAssertEqual(vm.conflict, ExternalConflict(diskContent: "внешняя версия"))
        // Пока конфликт не решён — автосохранение заморожено, диск не трогаем.
        waitForAutosave()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "внешняя версия")
    }

    func testConflictResolutionKeepingMine() throws {
        let url = try makeFile("заметка.md", contents: "база")
        let vm = makeVM()
        vm.open(url)
        vm.text = "мои правки"
        try "внешняя версия".write(to: url, atomically: true, encoding: .utf8)
        vm.checkExternalChange()

        vm.resolveConflictKeepingMine()

        // Мои правки — в копии рядом; оригинал — внешняя версия; конфликт снят.
        let copy = tempDir.appendingPathComponent("заметка (conflict).md")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "мои правки")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "внешняя версия")
        XCTAssertEqual(vm.text, "внешняя версия")
        XCTAssertNil(vm.conflict)
    }

    func testConflictResolutionReloadingDisk() throws {
        let url = try makeFile("заметка.md", contents: "база")
        let vm = makeVM()
        vm.open(url)
        vm.text = "мои правки"
        try "внешняя версия".write(to: url, atomically: true, encoding: .utf8)
        vm.checkExternalChange()

        vm.resolveConflictReloadingDisk()

        XCTAssertEqual(vm.text, "внешняя версия")
        XCTAssertNil(vm.conflict)
        XCTAssertFalse(vm.hasUnsavedChanges)
        // Копий не создано.
        let entries = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(entries.sorted(), ["заметка.md"])
    }

    func testOwnSaveEchoIsNotTreatedAsExternalChange() throws {
        let url = try makeFile("заметка.md", contents: "текст")
        let vm = makeVM()
        vm.open(url)
        vm.text = "текст правленый"
        waitForAutosave() // наша запись ушла на диск

        // FSEvents принесёт эхо нашей же записи — оно должно игнорироваться.
        vm.checkExternalChange()

        XCTAssertNil(vm.conflict)
        XCTAssertEqual(vm.text, "текст правленый")
    }
}

// MARK: - writeConflictCopy

final class ConflictCopyTests: VaultTestCase {

    func testWritesCopyWithConflictSuffixAndKeepsOriginal() throws {
        let original = try makeFile("Бюджет 2026.md", contents: "оригинал")

        let copy = try VaultFileOperations.writeConflictCopy(for: original, contents: "моя версия")

        XCTAssertEqual(copy.lastPathComponent, "Бюджет 2026 (conflict).md")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "моя версия")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "оригинал")
    }

    func testSecondCopyGetsUniqueName() throws {
        let original = try makeFile("заметка.md", contents: "оригинал")

        let first = try VaultFileOperations.writeConflictCopy(for: original, contents: "v1")
        let second = try VaultFileOperations.writeConflictCopy(for: original, contents: "v2")

        XCTAssertEqual(first.lastPathComponent, "заметка (conflict).md")
        XCTAssertEqual(second.lastPathComponent, "заметка (conflict) 2.md")
    }
}

// MARK: - MarkdownHighlighter

final class MarkdownHighlighterTests: XCTestCase {

    func testDetectsHeadingsWithLevels() {
        let text = "# Один\nтекст\n### Три\n####### не заголовок (7 решёток)"
        let headings = MarkdownHighlighter.matches(in: text).filter {
            if case .heading = $0.kind { return true } else { return false }
        }

        XCTAssertEqual(headings.count, 2)
        XCTAssertEqual(headings[0].kind, .heading(level: 1))
        XCTAssertEqual(headings[1].kind, .heading(level: 3))
    }

    func testDetectsBoldAndInlineCode() {
        let text = "тут **жирный** и `код` рядом"
        let kinds = MarkdownHighlighter.matches(in: text).map(\.kind)

        XCTAssertTrue(kinds.contains(.bold))
        XCTAssertTrue(kinds.contains(.inlineCode))
    }

    func testDetectsHighlightSyntax() {
        let text = "тут ==важно== выделено"
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .highlight }
        XCTAssertNotNil(match)
        XCTAssertEqual((text as NSString).substring(with: match!.range), "==важно==")
    }

    func testHighlightDoesNotSpanNewlines() {
        let kinds = MarkdownHighlighter.matches(in: "==раз\nдва==").map(\.kind)
        XCTAssertFalse(kinds.contains(.highlight))
    }

    func testDetectsFencedCodeBlockAndBlockquote() {
        let text = """
        > цитата
        ```
        let x = 1
        ```
        """
        let kinds = MarkdownHighlighter.matches(in: text).map(\.kind)

        XCTAssertTrue(kinds.contains(.codeBlock))
        XCTAssertTrue(kinds.contains(.blockquote))
    }

    // MARK: - markerRanges (Live Preview сворачивание — ConcealableMarker)

    func testBoldMarkerRangesCoverAsterisksOnly() {
        let text = "тут **жирный** текст"
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .bold }!
        let ns = text as NSString
        XCTAssertEqual(match.markerRanges.map { ns.substring(with: $0) }, ["**", "**"])
    }

    func testHighlightMarkerRangesCoverEqualsOnly() {
        let text = "тут ==важно== текст"
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .highlight }!
        let ns = text as NSString
        XCTAssertEqual(match.markerRanges.map { ns.substring(with: $0) }, ["==", "=="])
    }

    func testInlineCodeMarkerRangesCoverBackticksOnly() {
        let text = "тут `код` текст"
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .inlineCode }!
        let ns = text as NSString
        XCTAssertEqual(match.markerRanges.map { ns.substring(with: $0) }, ["`", "`"])
    }

    func testHeadingMarkerRangeCoversHashesOnly() {
        let text = "### Заголовок"
        let match = MarkdownHighlighter.matches(in: text).first { if case .heading = $0.kind { return true }; return false }!
        let ns = text as NSString
        XCTAssertEqual(match.markerRanges.map { ns.substring(with: $0) }, ["###"])
    }

    func testBlockquoteMarkerRangeCoversPrefixOnly() {
        let text = "> цитата тут"
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .blockquote }!
        let ns = text as NSString
        XCTAssertEqual(match.markerRanges.map { ns.substring(with: $0) }, ["> "])
    }

    func testCodeBlockHasNoMarkerRangesFromRegex() {
        let text = "```\nкод\n```"
        let match = MarkdownHighlighter.matches(in: text).first { $0.kind == .codeBlock }!
        // Границы код-блока считаются отдельно в ConcealableMarker, не отсюда.
        XCTAssertTrue(match.markerRanges.isEmpty)
    }

    func testMarkerRangesAreValidUTF16ForCyrillic() {
        let text = "## Финансы\nтут **жирное слово** и `код`, и > цитата"
        let ns = text as NSString
        for match in MarkdownHighlighter.matches(in: text) {
            for range in match.markerRanges {
                XCTAssertLessThanOrEqual(range.location + range.length, ns.length)
            }
        }
    }

    func testCyrillicRangesAreValidUTF16() {
        // Кириллица: NSRange (UTF-16) не должен выходить за пределы строки.
        let text = "## Финансы и активы\n**жирное слово** и `код`"
        let ns = text as NSString
        for match in MarkdownHighlighter.matches(in: text) {
            XCTAssertLessThanOrEqual(match.range.location + match.range.length, ns.length)
        }
    }
}

// MARK: - ChecklistParser

final class ChecklistParserTests: XCTestCase {

    func testParsesUncheckedAndChecked() {
        let text = "- [ ] купить молоко\n- [x] позвонить маме"
        let items = ChecklistParser.parse(text)

        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].isChecked)
        XCTAssertTrue(items[1].isChecked)
    }

    func testUppercaseXCountsAsChecked() {
        XCTAssertTrue(ChecklistParser.parse("- [X] готово")[0].isChecked)
    }

    func testAllBulletMarkersSupported() {
        let text = "- [ ] раз\n* [ ] два\n+ [ ] три"
        XCTAssertEqual(ChecklistParser.parse(text).count, 3)
    }

    func testNestedIndentationMatched() {
        let text = "  - [ ] родитель\n    - [x] вложенный пункт"
        let items = ChecklistParser.parse(text)

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[1].isChecked)
    }

    func testPlainBulletsNotMatched() {
        XCTAssertTrue(ChecklistParser.parse("- обычный пункт списка без чекбокса").isEmpty)
    }

    func testMarkerRangeCoversOnlyBrackets() {
        let text = "- [ ] купить молоко"
        let item = ChecklistParser.parse(text)[0]
        XCTAssertEqual((text as NSString).substring(with: item.markerRange), "[ ]")
    }

    func testContentRangeCoversTextAfterMarker() {
        let text = "- [x] позвонить маме"
        let item = ChecklistParser.parse(text)[0]
        XCTAssertEqual((text as NSString).substring(with: item.contentRange), " позвонить маме")
    }

    func testCyrillicRangesAreValidUTF16() {
        let text = "- [ ] Финансы и активы: закрыть ипотеку 🏦"
        let ns = text as NSString
        let item = ChecklistParser.parse(text)[0]
        XCTAssertLessThanOrEqual(item.contentRange.location + item.contentRange.length, ns.length)
    }

    func testToggledMarkerFlipsAndNormalizesCase() {
        XCTAssertEqual(ChecklistParser.toggledMarker(currentlyChecked: false), "[x]")
        XCTAssertEqual(ChecklistParser.toggledMarker(currentlyChecked: true), "[ ]")
    }
}

// MARK: - MarkdownTextView (переключение чеклиста в реальном NSTextStorage)

@MainActor
final class MarkdownTextViewChecklistTests: XCTestCase {

    func testToggleChecklistMarkerFlipsTextInStorage() {
        let textView = MarkdownTextView()
        textView.string = "- [ ] купить молоко"
        let item = ChecklistParser.parse(textView.string)[0]

        textView.toggleChecklistMarker(item)

        XCTAssertEqual(textView.string, "- [x] купить молоко")
    }

    func testToggleTwiceReturnsToOriginal() {
        let textView = MarkdownTextView()
        textView.string = "- [x] задача"
        let checked = ChecklistParser.parse(textView.string)[0]

        textView.toggleChecklistMarker(checked)
        let unchecked = ChecklistParser.parse(textView.string)[0]
        textView.toggleChecklistMarker(unchecked)

        XCTAssertEqual(textView.string, "- [x] задача")
    }

    func testToggleOnlyAffectsTargetedItem() {
        let textView = MarkdownTextView()
        textView.string = "- [ ] первый\n- [ ] второй"
        let second = ChecklistParser.parse(textView.string)[1]

        textView.toggleChecklistMarker(second)

        XCTAssertEqual(textView.string, "- [ ] первый\n- [x] второй")
    }
}
