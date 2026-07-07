// VaultTests.swift — тесты core-логики vault (задача 02).
//
// Покрытие:
//  - VaultTree: построение из temp-директории, сортировка «папки сначала»,
//    фильтрация dot-элементов, кириллица и пробелы в именах (у пользователя
//    «Финансы и активы» и т.п.);
//  - VaultFileOperations: create/rename/move/trash на temp-директории,
//    защита от перезаписи (инвариант №1);
//  - VaultID: детерминизм, уникальность, безопасный формат;
//  - Debouncer: схлопывание частых вызовов в один.

import XCTest
import Combine
@testable import SecondBrain

/// База: temp-директория на каждый тест, сносится в tearDown.
class VaultTestCase: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Создаёт файл с содержимым (по умолчанию пустой) по пути относительно tempDir.
    @discardableResult
    func makeFile(_ relativePath: String, contents: String = "") throws -> URL {
        let url = tempDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Создаёт папку по пути относительно tempDir.
    @discardableResult
    func makeDir(_ relativePath: String) throws -> URL {
        let url = tempDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - VaultTree

final class VaultTreeTests: VaultTestCase {

    func testBuildsNestedTreeWithCyrillicAndSpaces() throws {
        try makeFile("Финансы и активы/Бюджет 2026.md")
        try makeFile("Финансы и активы/Вклады/Список.md")
        try makeFile("Встречи/2026-07 план.md")
        try makeFile("README.md")

        let root = try VaultTree.build(at: tempDir)

        XCTAssertEqual(root.children?.count, 3) // Встречи, Финансы и активы, README.md
        let finance = root.children?.first { $0.name == "Финансы и активы" }
        XCTAssertNotNil(finance)
        XCTAssertTrue(finance!.isDirectory)
        XCTAssertEqual(finance?.children?.map(\.name), ["Вклады", "Бюджет 2026.md"])
    }

    func testFoldersSortedBeforeFiles() throws {
        try makeFile("aaa.md")
        try makeDir("zzz")

        let root = try VaultTree.build(at: tempDir)

        // Папка zzz раньше файла aaa.md, хотя по алфавиту позже.
        XCTAssertEqual(root.children?.map(\.name), ["zzz", "aaa.md"])
    }

    func testDotItemsHiddenByDefaultAndShownOnDemand() throws {
        try makeDir(".obsidian")
        try makeDir(".git")
        try makeDir(".trash")
        try makeFile(".DS_Store")
        try makeFile("Заметка.md")

        let hidden = try VaultTree.build(at: tempDir)
        XCTAssertEqual(hidden.children?.map(\.name), ["Заметка.md"])

        let shown = try VaultTree.build(at: tempDir, showsDotItems: true)
        XCTAssertEqual(shown.children?.count, 5)
    }

    func testBuildOnFileThrows() throws {
        let file = try makeFile("файл.md")
        XCTAssertThrowsError(try VaultTree.build(at: file)) { error in
            XCTAssertEqual(error as? VaultError, .notADirectory("файл.md"))
        }
    }

    func testFindLocatesDeepNode() throws {
        let target = try makeFile("а/б/в/глубокая заметка.md")
        let root = try VaultTree.build(at: tempDir)

        let found = root.find(target)
        XCTAssertEqual(found?.name, "глубокая заметка.md")
        XCTAssertNil(root.find(tempDir.appendingPathComponent("нет такого.md")))
    }

    func testAllFoldersListsEveryDirectoryIncludingRoot() throws {
        try makeDir("одна")
        try makeDir("одна/вложенная")
        try makeFile("файл.md")

        let root = try VaultTree.build(at: tempDir)
        let names = root.allFolders.map(\.name)

        XCTAssertEqual(names.count, 3) // корень + одна + вложенная
        XCTAssertTrue(names.contains("одна"))
        XCTAssertTrue(names.contains("вложенная"))
    }
}

// MARK: - VaultFileOperations

final class VaultFileOperationsTests: VaultTestCase {

    func testCreateNotePicksUniqueName() throws {
        let first = try VaultFileOperations.createNote(in: tempDir)
        let second = try VaultFileOperations.createNote(in: tempDir)

        XCTAssertEqual(first.lastPathComponent, "Без названия.md")
        XCTAssertEqual(second.lastPathComponent, "Без названия 2.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testCreateFolderPicksUniqueName() throws {
        let first = try VaultFileOperations.createFolder(in: tempDir)
        let second = try VaultFileOperations.createFolder(in: tempDir)

        XCTAssertEqual(first.lastPathComponent, "Новая папка")
        XCTAssertEqual(second.lastPathComponent, "Новая папка 2")
    }

    func testCreateFileRefusesExisting() throws {
        try makeFile("занято.txt", contents: "не перезаписывать!")

        XCTAssertThrowsError(try VaultFileOperations.createFile(in: tempDir, named: "занято.txt")) {
            XCTAssertEqual($0 as? VaultError, .alreadyExists("занято.txt"))
        }
        // Содержимое не тронуто — инвариант №1.
        let contents = try String(contentsOf: tempDir.appendingPathComponent("занято.txt"), encoding: .utf8)
        XCTAssertEqual(contents, "не перезаписывать!")
    }

    func testRenamePreservesContentsAndRefusesOccupiedName() throws {
        let source = try makeFile("старое имя.md", contents: "тело заметки")
        try makeFile("занято.md")

        let renamed = try VaultFileOperations.rename(source, to: "новое имя.md")
        XCTAssertEqual(renamed.lastPathComponent, "новое имя.md")
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "тело заметки")

        XCTAssertThrowsError(try VaultFileOperations.rename(renamed, to: "занято.md")) {
            XCTAssertEqual($0 as? VaultError, .alreadyExists("занято.md"))
        }
    }

    func testRenameRejectsInvalidNames() throws {
        let file = try makeFile("файл.md")
        for bad in ["", "   ", "a/b", ".скрытый"] {
            XCTAssertThrowsError(try VaultFileOperations.rename(file, to: bad), "имя: «\(bad)»")
        }
    }

    func testMoveIntoFolderAndRefuseOccupied() throws {
        let file = try makeFile("заметка.md", contents: "тело")
        let folder = try makeDir("Папка назначения")

        let moved = try VaultFileOperations.move(file, into: folder)
        XCTAssertEqual(moved.deletingLastPathComponent().lastPathComponent, "Папка назначения")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "тело")

        // Повторное перемещение файла с тем же именем в ту же папку — отказ.
        let duplicate = try makeFile("заметка.md")
        XCTAssertThrowsError(try VaultFileOperations.move(duplicate, into: folder)) {
            XCTAssertEqual($0 as? VaultError, .alreadyExists("заметка.md"))
        }
    }

    func testMoveFolderInsideItselfRefused() throws {
        let outer = try makeDir("внешняя")
        let inner = try makeDir("внешняя/внутренняя")

        XCTAssertThrowsError(try VaultFileOperations.move(outer, into: inner))
    }

    func testTrashRemovesFromOriginalLocation() throws {
        let file = try makeFile("в корзину.md")

        try VaultFileOperations.trash(file)

        // Файл исчез из исходного места (и лежит в Корзине — руками не проверить).
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

// MARK: - VaultID

final class VaultIDTests: XCTestCase {

    func testDeterministicAndPathSensitive() {
        let a = URL(fileURLWithPath: "/Users/test/Obsidian Vault/Второй мозг")
        let b = URL(fileURLWithPath: "/Users/test/Другая папка")

        XCTAssertEqual(VaultID.make(for: a), VaultID.make(for: a))
        XCTAssertNotEqual(VaultID.make(for: a), VaultID.make(for: b))
    }

    func testFormatIsSafeForDirectoryName() {
        let id = VaultID.make(for: URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    }

    func testTrailingSlashDoesNotChangeID() {
        let plain = URL(fileURLWithPath: "/tmp/vault")
        let slashed = URL(fileURLWithPath: "/tmp/vault/")
        XCTAssertEqual(VaultID.make(for: plain), VaultID.make(for: slashed))
    }
}

// MARK: - VaultManager (bookmark + восстановление)

@MainActor
final class VaultManagerTests: VaultTestCase {

    /// Критерий приёмки: после перезапуска приложение само открывает последний
    /// vault. Эмулируем перезапуск вторым VaultManager на тех же UserDefaults.
    func testOpenVaultSavesBookmarkAndRestoresAfterRelaunch() throws {
        let suiteName = "VaultManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try makeFile("заметка.md")

        let manager = VaultManager(defaults: defaults, restoreLast: false)
        manager.openVault(at: tempDir)

        XCTAssertNotNil(manager.root)
        XCTAssertEqual(manager.recentVaults.count, 1)
        XCTAssertEqual(manager.vaultID?.count, 16)
        manager.closeVault()
        XCTAssertNil(manager.root)

        // «Перезапуск»: новый менеджер, те же defaults → vault открыт сам.
        let relaunched = VaultManager(defaults: defaults, restoreLast: true)
        // Bookmark может вернуть путь через /private — сравниваем с учётом симлинков.
        XCTAssertEqual(
            relaunched.vaultURL?.resolvingSymlinksInPath().path,
            tempDir.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(relaunched.root?.children?.map(\.name), ["заметка.md"])
        relaunched.closeVault()
    }

    /// CRUD через менеджер: создание выделяет результат, ошибка публикуется в lastError.
    func testCreateNoteSelectsResultAndReportsErrors() throws {
        let suiteName = "VaultManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = VaultManager(defaults: defaults, restoreLast: false)
        manager.openVault(at: tempDir)

        manager.createNote()
        XCTAssertEqual(manager.selection?.lastPathComponent, "Без названия.md")

        // Ошибка не глотается: rename в занятое имя → lastError.
        manager.createNote() // «Без названия 2.md»
        let node = try XCTUnwrap(manager.root?.find(XCTUnwrap(manager.selection)))
        manager.rename(node, to: "Без названия.md")
        XCTAssertEqual(manager.lastError, .alreadyExists("Без названия.md"))
        manager.closeVault()
    }

    /// Регрессия задачи 03: правка ТОЛЬКО содержимого файла (дерево не меняется)
    /// обязана двигать diskChangeTick — на него подписан редактор для
    /// checkExternalChange. Реальный FSEvents, поэтому щедрый таймаут.
    func testContentOnlyChangeBumpsDiskChangeTick() throws {
        let suiteName = "VaultManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let file = try makeFile("заметка.md", contents: "версия 1")

        let manager = VaultManager(defaults: defaults, restoreLast: false)
        manager.openVault(at: tempDir)

        let ticked = expectation(description: "FSEvents доставил изменение")
        let cancellable = manager.$diskChangeTick
            .dropFirst()
            .sink { _ in ticked.fulfill() }
        defer { cancellable.cancel() }

        // Внешняя правка содержимого — имена/структура не меняются.
        try "версия 2".write(to: file, atomically: true, encoding: .utf8)

        wait(for: [ticked], timeout: 5.0)
        manager.closeVault()
    }
}

// MARK: - Debouncer

final class DebouncerTests: XCTestCase {

    /// Три быстрых schedule → один вызов (последний).
    func testCoalescesRapidCalls() {
        let debouncer = Debouncer(delay: 0.05, queue: .main)
        let fired = expectation(description: "debounced")
        var count = 0

        debouncer.schedule { count += 1; XCTFail("отменённый вызов не должен сработать") }
        debouncer.schedule { count += 1; XCTFail("отменённый вызов не должен сработать") }
        debouncer.schedule { count += 1; fired.fulfill() }

        wait(for: [fired], timeout: 1.0)
        XCTAssertEqual(count, 1)
    }

    /// cancel() снимает запланированный вызов.
    func testCancelPreventsExecution() {
        let debouncer = Debouncer(delay: 0.05, queue: .main)
        let waited = expectation(description: "пауза прошла")

        debouncer.schedule { XCTFail("после cancel вызова быть не должно") }
        debouncer.cancel()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { waited.fulfill() }
        wait(for: [waited], timeout: 1.0)
    }
}
