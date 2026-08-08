// FileToolsTests.swift — тесты файловых инструментов (задача 39).
//
// search_files / write_file / edit_file / delete_file на временных папках:
// капы, SafePath-отказы, vault-safety (read-before-write + mtime-guard),
// стейт FileOpsContext (реестр чтений, накопление изменений) и превью diff'а
// для карточки подтверждения.

import XCTest
@testable import SecondBrain

final class FileToolsTests: XCTestCase {

    private var root: URL!
    private var executor: ToolExecutor!
    private var fileOps: FileOpsContext!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetools-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executor = ToolExecutor(registry: ToolRegistry.projectTools(repoRoot: root),
                                repoRoot: root)
        fileOps = FileOpsContext()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Выполнение с файловым контекстом чата.
    private func run(_ name: String, _ argumentsJSON: String) async -> String {
        await executor.execute(name: name, argumentsJSON: argumentsJSON, fileOps: fileOps)
    }

    // MARK: - search_files

    func testSearchFindsSubstringCaseInsensitive() async throws {
        try write("Привет Мир\nвторая строка\n", to: "a.md")
        try write("ничего\n", to: "b.md")
        let result = await run("search_files", #"{"query":"привет мир"}"#)
        XCTAssertTrue(result.contains("a.md:1:"), result)
        XCTAssertFalse(result.contains("b.md"), result)
        XCTAssertTrue(result.contains("Найдено: 1 совпадений в 1 файлах"), result)
    }

    func testSearchFiltersByPathAndExtension() async throws {
        try write("маркер\n", to: "docs/x.md")
        try write("маркер\n", to: "src/y.swift")
        let byPath = await run("search_files", #"{"query":"маркер","path":"docs"}"#)
        XCTAssertTrue(byPath.contains("docs/x.md"), byPath)
        XCTAssertFalse(byPath.contains("src/y.swift"), byPath)

        let byExt = await run("search_files", #"{"query":"маркер","extension":"swift"}"#)
        XCTAssertTrue(byExt.contains("src/y.swift"), byExt)
        XCTAssertFalse(byExt.contains("docs/x.md"), byExt)
    }

    func testSearchRespectsMaxResults() async throws {
        let lines = (1...30).map { "маркер \($0)" }.joined(separator: "\n")
        try write(lines, to: "many.md")
        let result = await run("search_files", #"{"query":"маркер","maxResults":5}"#)
        let matches = result.components(separatedBy: "\n").filter { $0.contains("many.md:") }
        XCTAssertEqual(matches.count, 5, result)
        XCTAssertTrue(result.contains("обрезан"), result)
    }

    func testSearchSkipsBinaryAndValidatesArguments() async throws {
        // Бинарник содержит те же байты «mark», но NUL исключает его из поиска.
        try Data([0x6D, 0x61, 0x72, 0x6B, 0x00]).write(
            to: root.appendingPathComponent("bin.dat"))
        try write("mark в тексте\n", to: "t.md")
        let result = await run("search_files", #"{"query":"mark"}"#)
        XCTAssertTrue(result.contains("t.md"), result)
        XCTAssertFalse(result.contains("bin.dat"), result)

        let escape = await run("search_files", #"{"query":"x","path":"../"}"#)
        XCTAssertTrue(escape.hasPrefix("ERROR:"), escape)

        let noQuery = await run("search_files", "{}")
        XCTAssertTrue(noQuery.hasPrefix("ERROR:"), noQuery)
    }

    func testSearchNothingFoundIsNotError() async throws {
        try write("текст\n", to: "a.md")
        let result = await run("search_files", #"{"query":"такого нет"}"#)
        XCTAssertFalse(result.hasPrefix("ERROR:"), result)
        XCTAssertTrue(result.contains("Ничего не найдено"), result)
    }

    // MARK: - write_file

    func testWriteCreatesFileAndIntermediateDirectories() async throws {
        let result = await run("write_file",
                               ##"{"path":"notes/new/файл.md","content":"# Заголовок\n"}"##)
        XCTAssertTrue(result.hasPrefix("OK: создан"), result)
        XCTAssertEqual(try read("notes/new/файл.md"), "# Заголовок\n")
        // Изменение записано в контекст с diff'ом создания.
        let changes = await fileOps.drainChanges()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .created)
        XCTAssertTrue(changes[0].diff.contains("+# Заголовок"), changes[0].diff)
    }

    /// Vault-safety: перезапись существующего без чтения — отказ.
    func testOverwriteWithoutReadIsRejected() async throws {
        try write("оригинал\n", to: "a.md")
        let result = await run("write_file", #"{"path":"a.md","content":"замена\n"}"#)
        XCTAssertTrue(result.hasPrefix("ERROR:"), result)
        XCTAssertTrue(result.contains("read_file"), result)
        XCTAssertEqual(try read("a.md"), "оригинал\n")
    }

    func testOverwriteAfterReadSucceeds() async throws {
        try write("оригинал\n", to: "a.md")
        _ = await run("read_file", #"{"path":"a.md"}"#)
        let result = await run("write_file", #"{"path":"a.md","content":"замена\n"}"#)
        XCTAssertTrue(result.hasPrefix("OK: перезаписан"), result)
        XCTAssertEqual(try read("a.md"), "замена\n")
        let changes = await fileOps.drainChanges()
        XCTAssertEqual(changes.first?.kind, .modified)
        XCTAssertTrue(changes.first?.diff.contains("-оригинал") == true)
    }

    /// mtime-guard: файл изменился на диске после чтения → отказ.
    func testOverwriteAfterExternalChangeIsRejected() async throws {
        try write("оригинал\n", to: "a.md")
        _ = await run("read_file", #"{"path":"a.md"}"#)
        // Внешнее изменение (mtime в будущее — надёжнее сна).
        try write("внешняя правка\n", to: "a.md")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: root.appendingPathComponent("a.md").path)
        let result = await run("write_file", #"{"path":"a.md","content":"замена\n"}"#)
        XCTAssertTrue(result.hasPrefix("ERROR:"), result)
        XCTAssertTrue(result.contains("изменился"), result)
        XCTAssertEqual(try read("a.md"), "внешняя правка\n")
    }

    /// Серия правок одного файла в одном ходе: собственная запись обновляет
    /// реестр чтений — второй write не спотыкается о guard.
    func testConsecutiveWritesSameTurn() async throws {
        _ = await run("write_file", #"{"path":"a.md","content":"v1\n"}"#)
        let second = await run("write_file", #"{"path":"a.md","content":"v2\n"}"#)
        XCTAssertTrue(second.hasPrefix("OK:"), second)
        XCTAssertEqual(try read("a.md"), "v2\n")
    }

    func testWriteRejectsEscapeAndOversizeAndNoContext() async throws {
        let escape = await run("write_file", #"{"path":"../evil.md","content":"x"}"#)
        XCTAssertTrue(escape.hasPrefix("ERROR:"), escape)

        let big = String(repeating: "x", count: FileToolSupport.maxWriteBytes + 1)
        let oversize = await run("write_file",
                                 #"{"path":"big.md","content":"\#(big)"}"#)
        XCTAssertTrue(oversize.hasPrefix("ERROR:"), oversize)

        // Без контекста чата запись недоступна.
        let noContext = await executor.execute(name: "write_file",
                                               argumentsJSON: #"{"path":"a.md","content":"x"}"#)
        XCTAssertTrue(noContext.hasPrefix("ERROR:"), noContext)
    }

    // MARK: - edit_file

    func testEditReplacesUniqueFragment() async throws {
        try write("один\nдва\nтри\n", to: "a.md")
        _ = await run("read_file", #"{"path":"a.md"}"#)
        let result = await run("edit_file",
                               #"{"path":"a.md","old_string":"два","new_string":"ДВА"}"#)
        XCTAssertTrue(result.hasPrefix("OK:"), result)
        XCTAssertEqual(try read("a.md"), "один\nДВА\nтри\n")
    }

    /// read_file без расширения (fallback на .md) регистрирует в mtime-guard
    /// РЕАЛЬНЫЙ путь «a.md», поэтому последующий edit_file по «a.md» проходит
    /// без «сначала прочитай файл».
    func testReadFileMdFallbackRegistersRealPathForGuard() async throws {
        try write("один\nдва\nтри\n", to: "a.md")
        let readResult = await run("read_file", #"{"path":"a"}"#)   // без .md
        XCTAssertTrue(readResult.contains("два"), "fallback прочитал a.md: \(readResult)")
        let edit = await run("edit_file",
                             #"{"path":"a.md","old_string":"два","new_string":"ДВА"}"#)
        XCTAssertTrue(edit.hasPrefix("OK:"), "guard пройден по a.md: \(edit)")
    }

    func testEditNotFoundAndAmbiguous() async throws {
        try write("яблоко\nяблоко\n", to: "a.md")
        _ = await run("read_file", #"{"path":"a.md"}"#)

        let notFound = await run("edit_file",
                                 #"{"path":"a.md","old_string":"груша","new_string":"x"}"#)
        XCTAssertTrue(notFound.hasPrefix("ERROR:"), notFound)
        XCTAssertTrue(notFound.contains("не найден"), notFound)

        let ambiguous = await run("edit_file",
                                  #"{"path":"a.md","old_string":"яблоко","new_string":"x"}"#)
        XCTAssertTrue(ambiguous.hasPrefix("ERROR:"), ambiguous)
        XCTAssertTrue(ambiguous.contains("2 раз"), ambiguous)
    }

    func testEditReplaceAll() async throws {
        try write("яблоко и яблоко\n", to: "a.md")
        _ = await run("read_file", #"{"path":"a.md"}"#)
        let result = await run(
            "edit_file",
            #"{"path":"a.md","old_string":"яблоко","new_string":"груша","replace_all":true}"#)
        XCTAssertTrue(result.hasPrefix("OK:"), result)
        XCTAssertEqual(try read("a.md"), "груша и груша\n")
    }

    /// edit_file требует предварительного чтения (тот же mtime-guard).
    func testEditWithoutReadIsRejected() async throws {
        try write("текст\n", to: "a.md")
        let result = await run("edit_file",
                               #"{"path":"a.md","old_string":"текст","new_string":"x"}"#)
        XCTAssertTrue(result.hasPrefix("ERROR:"), result)
        XCTAssertTrue(result.contains("read_file"), result)
    }

    // MARK: - delete_file

    func testDeleteMovesToTrash() async throws {
        try write("удали меня\n", to: "old.md")
        let result = await run("delete_file", #"{"path":"old.md"}"#)
        XCTAssertTrue(result.hasPrefix("OK:"), result)
        XCTAssertTrue(result.contains("Корзину"), result)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("old.md").path))
        let changes = await fileOps.drainChanges()
        XCTAssertEqual(changes.first?.kind, .deleted)
    }

    func testDeleteMissingAndDirectoryAndEscape() async throws {
        let missing = await run("delete_file", #"{"path":"нет.md"}"#)
        XCTAssertTrue(missing.hasPrefix("ERROR:"), missing)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"),
                                                withIntermediateDirectories: true)
        let directory = await run("delete_file", #"{"path":"dir"}"#)
        XCTAssertTrue(directory.hasPrefix("ERROR:"), directory)

        let escape = await run("delete_file", #"{"path":"../x"}"#)
        XCTAssertTrue(escape.hasPrefix("ERROR:"), escape)
    }

    // MARK: - FileOpsContext

    func testDrainChangesEmptiesAccumulator() async {
        await fileOps.record(FileChangeDisplay(relativePath: "a", kind: .created, diff: "d"))
        let first = await fileOps.drainChanges()
        XCTAssertEqual(first.count, 1)
        let second = await fileOps.drainChanges()
        XCTAssertTrue(second.isEmpty)
    }

    /// Обрезанное чтение НЕ регистрируется — перезапись после него отклоняется.
    func testTruncatedReadDoesNotAllowOverwrite() async throws {
        let big = String(repeating: "я", count: 2000)
        try write(big, to: "big.md")
        _ = await run("read_file", #"{"path":"big.md","maxBytes":100}"#)
        let result = await run("write_file", #"{"path":"big.md","content":"x"}"#)
        XCTAssertTrue(result.hasPrefix("ERROR:"), result)
    }

    // MARK: - Превью для карточки подтверждения

    func testPreviewDetailForWriteEditCommandDelete() async throws {
        try write("один\nдва\n", to: "a.md")

        let writePreview = FileChangePreview.detail(
            toolName: "write_file",
            argumentsJSON: #"{"path":"a.md","content":"один\nДВА\n"}"#,
            root: root)
        XCTAssertTrue(writePreview?.contains("-два") == true, writePreview ?? "nil")
        XCTAssertTrue(writePreview?.contains("+ДВА") == true, writePreview ?? "nil")

        let editPreview = FileChangePreview.detail(
            toolName: "edit_file",
            argumentsJSON: #"{"path":"a.md","old_string":"два","new_string":"2"}"#,
            root: root)
        XCTAssertTrue(editPreview?.contains("+2") == true, editPreview ?? "nil")

        let commandPreview = FileChangePreview.detail(
            toolName: "run_command",
            argumentsJSON: #"{"command":"git push"}"#,
            root: root)
        XCTAssertEqual(commandPreview, "$ git push")

        let deletePreview = FileChangePreview.detail(
            toolName: "delete_file",
            argumentsJSON: #"{"path":"a.md"}"#,
            root: root)
        XCTAssertTrue(deletePreview?.contains("a.md") == true)

        // Неизвестный инструмент/MCP — превью нет (карточка покажет аргументы).
        XCTAssertNil(FileChangePreview.detail(toolName: "srv__tool",
                                              argumentsJSON: "{}", root: root))
    }
}
