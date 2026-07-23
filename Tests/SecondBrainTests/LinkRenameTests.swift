// LinkRenameTests.swift — тесты починки [[ссылок]] при переименовании (задача 52).
//
// Что покрыто:
//  - WikilinkRenamer (чистое ядро): все формы ссылок, кириллица, пробелы в
//    новом имени, регистр цели, код-блоки, коллизия имён (цель не в множестве),
//    несколько ссылок в файле, ноль замен, суперстрока имени;
//  - LinkRenameApplier + LinkIndex (интеграция на temp-vault): переименование
//    чинит ссылки во всех файлах; коллизия имён не задевает чужую заметку.

import XCTest
@testable import SecondBrain

// MARK: - Чистое ядро

final class WikilinkRenamerTests: XCTestCase {

    func testAllFormsRewritten() {
        // targets — строчные, как их строит LinkRenameApplier.
        let targets: Set<String> = ["старое", "папка/старое"]
        let cases: [(String, String)] = [
            ("[[Старое]]", "[[Новое]]"),
            ("[[Старое|показать]]", "[[Новое|показать]]"),
            ("[[Старое#Раздел]]", "[[Новое#Раздел]]"),
            ("[[Старое#Раздел|показать]]", "[[Новое#Раздел|показать]]"),
            ("[[папка/Старое]]", "[[папка/Новое]]"),
            ("[[папка/Старое#Р|а]]", "[[папка/Новое#Р|а]]"),
            ("[[ Старое ]]", "[[ Новое ]]"),        // внешние пробелы сохраняются
            ("[[старое]]", "[[Новое]]"),            // регистр цели не важен, имя — как задано
        ]
        for (input, expected) in cases {
            let r = WikilinkRenamer.rewrite(content: input, targets: targets, to: "Новое")
            XCTAssertEqual(r.content, expected, input)
            XCTAssertEqual(r.replacements, 1, input)
        }
    }

    func testTargetNotInSetUntouched() {
        // Коллизия: голая [[Старое]] резолвится в другой файл — её не трогаем.
        let r = WikilinkRenamer.rewrite(
            content: "[[Старое]] и [[глубоко/Старое]]",
            targets: ["глубоко/старое"],
            to: "Новое"
        )
        XCTAssertEqual(r.content, "[[Старое]] и [[глубоко/Новое]]")
        XCTAssertEqual(r.replacements, 1)
    }

    func testLinksInCodeNotRewritten() {
        let text = """
        [[Старое]]
        `[[Старое]]`
        ```
        [[Старое]]
        ```
        """
        let r = WikilinkRenamer.rewrite(content: text, targets: ["старое"], to: "Новое")
        XCTAssertEqual(r.replacements, 1)
        XCTAssertEqual(text.components(separatedBy: "[[Старое]]").count - 1, 3)
        XCTAssertEqual(r.content.components(separatedBy: "[[Новое]]").count - 1, 1) // только вне кода
        XCTAssertEqual(r.content.components(separatedBy: "[[Старое]]").count - 1, 2) // в коде — целы
    }

    func testMultipleOccurrencesInOneFile() {
        let text = "нач [[Старое|a]] сер [[Другое]] кон [[Старое#x]]"
        let r = WikilinkRenamer.rewrite(content: text, targets: ["старое"], to: "Новое")
        XCTAssertEqual(r.content, "нач [[Новое|a]] сер [[Другое]] кон [[Новое#x]]")
        XCTAssertEqual(r.replacements, 2)
    }

    func testNewNameWithSpacesPreservesHeadingAndAlias() {
        let r = WikilinkRenamer.rewrite(content: "[[Старое#H|A]]", targets: ["старое"], to: "Новое имя")
        XCTAssertEqual(r.content, "[[Новое имя#H|A]]")
        XCTAssertEqual(r.replacements, 1)
    }

    func testSuperstringNotMatched() {
        // «Старое2» — другая заметка; при переименовании «Старое» не трогается.
        let r = WikilinkRenamer.rewrite(content: "[[Старое2]] [[Старое]]", targets: ["старое"], to: "Новое")
        XCTAssertEqual(r.content, "[[Старое2]] [[Новое]]")
        XCTAssertEqual(r.replacements, 1)
    }

    func testNoOpCases() {
        XCTAssertEqual(
            WikilinkRenamer.rewrite(content: "нет ссылок", targets: ["старое"], to: "Новое"),
            WikilinkRenamer.Rewrite(content: "нет ссылок", replacements: 0)
        )
        XCTAssertEqual(WikilinkRenamer.rewrite(content: "[[Старое]]", targets: [], to: "Новое").replacements, 0)
        XCTAssertEqual(WikilinkRenamer.rewrite(content: "[[Другое]]", targets: ["старое"], to: "Новое").replacements, 0)
    }
}

// MARK: - Интеграция: LinkIndex + LinkRenameApplier на temp-vault

final class LinkRenameIntegrationTests: VaultTestCase {

    func testRenameFixesLinksAcrossVault() throws {
        try makeFile("Старое.md", contents: "я заметка")
        try makeFile("A.md", contents: "см [[Старое]] и [[Старое|алиас]]")
        try makeFile("sub/B.md", contents: "путь [[Старое#Глава]] тут")

        let index = LinkIndex(root: tempDir)
        index.buildFull()
        let oldURL = tempDir.appendingPathComponent("Старое.md")
        let backlinks = index.backlinks(to: oldURL)
        XCTAssertEqual(backlinks.count, 3, "две ссылки в A + одна в B")

        let newURL = try VaultFileOperations.rename(oldURL, to: "Новое.md")
        let failures = LinkRenameApplier.apply(
            backlinks: backlinks,
            to: newURL.deletingPathExtension().lastPathComponent
        )
        XCTAssertTrue(failures.isEmpty)

        let a = try String(contentsOf: tempDir.appendingPathComponent("A.md"), encoding: .utf8)
        let b = try String(contentsOf: tempDir.appendingPathComponent("sub/B.md"), encoding: .utf8)
        XCTAssertEqual(a, "см [[Новое]] и [[Новое|алиас]]")
        XCTAssertEqual(b, "путь [[Новое#Глава]] тут")
    }

    func testCollisionKeepsOtherTargetIntact() throws {
        // Два файла с базовым именем «Заметка»: в корне и в под-папке.
        try makeFile("Заметка.md", contents: "корневая")
        try makeFile("глубоко/Заметка.md", contents: "глубокая")
        try makeFile("Ссылки.md", contents: "[[Заметка]] и [[глубоко/Заметка]]")

        let index = LinkIndex(root: tempDir)
        index.buildFull()
        // Переименовываем ГЛУБОКУЮ: голая [[Заметка]] резолвится в корневую
        // (кратчайший путь) и меняться не должна.
        let deepURL = tempDir.appendingPathComponent("глубоко/Заметка.md")
        let backlinks = index.backlinks(to: deepURL)
        XCTAssertEqual(backlinks.count, 1, "только путь-ссылка [[глубоко/Заметка]]")

        let newURL = try VaultFileOperations.rename(deepURL, to: "Переименована.md")
        LinkRenameApplier.apply(backlinks: backlinks, to: newURL.deletingPathExtension().lastPathComponent)

        let links = try String(contentsOf: tempDir.appendingPathComponent("Ссылки.md"), encoding: .utf8)
        XCTAssertEqual(links, "[[Заметка]] и [[глубоко/Переименована]]")
    }
}
