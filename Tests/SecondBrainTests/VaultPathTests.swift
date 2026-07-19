// VaultPathTests.swift — тесты VaultPath (задача 42).
//
// Покрытие:
//  - segments: файл в корне, вложенный путь, сам корень, url вне vault,
//    кириллица и пробелы, нестандартизованные URL, ловушка префикса имён
//    («/x/Notes» не должен считать «/x/NotesBackup/…» своим), папка как цель;
//  - ancestorPaths: контракт «без корня и без самой цели», пустота для
//    корневых файлов и целей вне vault.
//
// VaultPath не трогает ФС, поэтому базовый XCTestCase без temp-директорий.

import XCTest
@testable import SecondBrain

final class VaultPathTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/Users/test/Vault")

    // MARK: - segments

    func testFileAtVaultRootHasTwoSegments() {
        let file = root.appendingPathComponent("Заметка.md")
        let segments = VaultPath.segments(for: file, isDirectory: false, vaultRoot: root)

        XCTAssertEqual(segments?.map(\.name), ["Vault", "Заметка.md"])
        XCTAssertEqual(segments?.map(\.isDirectory), [true, false])
        XCTAssertEqual(segments?.last?.url.path, "/Users/test/Vault/Заметка.md")
    }

    func testNestedFileBuildsFullChain() {
        let file = root.appendingPathComponent("a/b/c.md")
        let segments = VaultPath.segments(for: file, isDirectory: false, vaultRoot: root)

        XCTAssertEqual(segments?.map(\.name), ["Vault", "a", "b", "c.md"])
        // Промежуточные сегменты — папки, последний — файл.
        XCTAssertEqual(segments?.map(\.isDirectory), [true, true, true, false])
        // URL сегментов накапливаются от корня — для навигации по клику.
        XCTAssertEqual(segments?[1].url.path, "/Users/test/Vault/a")
        XCTAssertEqual(segments?[2].url.path, "/Users/test/Vault/a/b")
    }

    func testVaultRootItselfIsSingleSegment() {
        let segments = VaultPath.segments(for: root, isDirectory: true, vaultRoot: root)

        XCTAssertEqual(segments?.map(\.name), ["Vault"])
        XCTAssertEqual(segments?.first?.isDirectory, true)
    }

    func testURLOutsideVaultReturnsNil() {
        let outside = URL(fileURLWithPath: "/Users/test/Other/note.md")
        XCTAssertNil(VaultPath.segments(for: outside, isDirectory: false, vaultRoot: root))
    }

    func testSiblingWithCommonNamePrefixIsOutside() {
        // Ловушка префикса: «/x/NotesBackup» начинается со строки «/x/Notes»,
        // но НЕ лежит внутри vault «/x/Notes» — граница компонента обязательна.
        let vault = URL(fileURLWithPath: "/x/Notes")
        let trap = URL(fileURLWithPath: "/x/NotesBackup/a.md")
        XCTAssertNil(VaultPath.segments(for: trap, isDirectory: false, vaultRoot: vault))
        XCTAssertTrue(VaultPath.ancestorPaths(of: trap, within: vault).isEmpty)
    }

    func testCyrillicAndSpacesInNames() {
        let file = root.appendingPathComponent("Финансы и активы/Бюджет 2026.md")
        let segments = VaultPath.segments(for: file, isDirectory: false, vaultRoot: root)

        XCTAssertEqual(segments?.map(\.name), ["Vault", "Финансы и активы", "Бюджет 2026.md"])
    }

    func testNonStandardizedURLsAreNormalized() {
        // Точки, двойные слэши и хвостовой слэш у корня не должны ломать разбор.
        let messyRoot = URL(fileURLWithPath: "/Users/test/Vault/")
        let messyFile = URL(fileURLWithPath: "/Users/test/./Vault//a/b.md")
        let segments = VaultPath.segments(for: messyFile, isDirectory: false, vaultRoot: messyRoot)

        XCTAssertEqual(segments?.map(\.name), ["Vault", "a", "b.md"])
    }

    func testFolderAsTargetKeepsDirectoryFlag() {
        let folder = root.appendingPathComponent("a/b")
        let segments = VaultPath.segments(for: folder, isDirectory: true, vaultRoot: root)

        XCTAssertEqual(segments?.map(\.name), ["Vault", "a", "b"])
        XCTAssertEqual(segments?.last?.isDirectory, true)
    }

    // MARK: - ancestorPaths

    func testAncestorsOfRootLevelFileAreEmpty() {
        let file = root.appendingPathComponent("Заметка.md")
        XCTAssertTrue(VaultPath.ancestorPaths(of: file, within: root).isEmpty)
    }

    func testAncestorsOfNestedFileExcludeRootAndTarget() {
        let file = root.appendingPathComponent("a/b/c.md")
        let ancestors = VaultPath.ancestorPaths(of: file, within: root)

        XCTAssertEqual(ancestors, ["/Users/test/Vault/a", "/Users/test/Vault/a/b"])
    }

    func testAncestorsOfFolderDoNotIncludeTheFolderItself() {
        // Контракт: раскрываем предков цели, но не саму цель — выбранную
        // папку достаточно показать, разворачивать её не обязательно.
        let folder = root.appendingPathComponent("a/b")
        let ancestors = VaultPath.ancestorPaths(of: folder, within: root)

        XCTAssertEqual(ancestors, ["/Users/test/Vault/a"])
    }

    func testAncestorsOfVaultRootAreEmpty() {
        XCTAssertTrue(VaultPath.ancestorPaths(of: root, within: root).isEmpty)
    }

    func testAncestorsOutsideVaultAreEmpty() {
        let outside = URL(fileURLWithPath: "/Users/test/Other/a/b.md")
        XCTAssertTrue(VaultPath.ancestorPaths(of: outside, within: root).isEmpty)
    }
}
