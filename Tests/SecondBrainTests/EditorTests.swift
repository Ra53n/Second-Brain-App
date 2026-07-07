// EditorTests.swift — тесты EditorViewModel и conflict-копий (задача 03).
//
// Покрытие:
//  - загрузка/переключение файлов, сохранение при переключении;
//  - debounce-автосохранение (короткий интервал вместо инжектируемых часов —
//    поведение то же, ожидание в тестах миллисекунды);
//  - внешнее изменение: тихое перечитывание без правок, конфликт с правками,
//    оба исхода конфликта;
//  - writeConflictCopy: суффикс «(conflict)», уникальность, оригинал не тронут;
//  - MarkdownHighlighter: диапазоны заголовков/жирного/кода.

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

    func testCyrillicRangesAreValidUTF16() {
        // Кириллица: NSRange (UTF-16) не должен выходить за пределы строки.
        let text = "## Финансы и активы\n**жирное слово** и `код`"
        let ns = text as NSString
        for match in MarkdownHighlighter.matches(in: text) {
            XCTAssertLessThanOrEqual(match.range.location + match.range.length, ns.length)
        }
    }
}
