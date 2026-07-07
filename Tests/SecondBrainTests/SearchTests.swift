// SearchTests.swift — тесты поискового индекса FTS5 (задача 05).
//
// Все базы — «:memory:» (как в RagTests MA). Покрытие по критериям приёмки:
// доступность FTS5 в системном libsqlite3, индексация temp-vault, кириллица и
// латиница, сниппеты, инкрементальное обновление (изменён/удалён/добавлен),
// полное пересоздание, построение MATCH-запроса.

import XCTest
import SQLite3
@testable import SecondBrain

final class SearchIndexTests: VaultTestCase {

    private func makeIndex() throws -> SearchIndex {
        let index = try SearchIndex(path: ":memory:")
        try index.refresh(root: tempDir)
        return index
    }

    /// Подсказка задачи: зафиксировать, что FTS5 есть в системном libsqlite3.
    func testFTS5AvailableInSystemSQLite() {
        XCTAssertEqual(sqlite3_compileoption_used("ENABLE_FTS5"), 1,
                       "системный libsqlite3 собран без FTS5 — поиск работать не будет")
    }

    func testSearchCyrillicAndLatin() throws {
        try makeFile("Финансы.md", contents: "Бюджет на квартал: доходы и расходы.")
        try makeFile("Project.md", contents: "Kickoff meeting notes for the roadmap.")
        let index = try makeIndex()

        XCTAssertEqual(try index.search("бюджет").map(\.title), ["Финансы"])
        XCTAssertEqual(try index.search("roadmap").map(\.title), ["Project"])
        // Регистр не важен, кириллица тоже (unicode61).
        XCTAssertEqual(try index.search("БЮДЖЕТ").map(\.title), ["Финансы"])
    }

    func testPrefixSearch() throws {
        try makeFile("Встречи.md", contents: "Обсудили транскрипцию встреч.")
        let index = try makeIndex()

        // Префикс слова — уже находит (звёздочка в ftsQuery).
        XCTAssertEqual(try index.search("транскри").count, 1)
    }

    func testTitleMatchesFileName() throws {
        try makeFile("Уникальное имя файла.md", contents: "тело без особых слов")
        let index = try makeIndex()

        XCTAssertEqual(try index.search("уникальное").count, 1)
    }

    func testSnippetContainsMarkedMatch() throws {
        try makeFile("Заметка.md", contents: "Начало текста. Здесь слово градиент в середине. Конец.")
        let index = try makeIndex()

        let hit = try XCTUnwrap(try index.search("градиент").first)
        XCTAssertTrue(hit.snippet.contains("\(SearchIndex.matchStart)градиент\(SearchIndex.matchEnd)"))
    }

    func testIncrementalRefreshHandlesChangeAddRemove() throws {
        let changing = try makeFile("Меняющаяся.md", contents: "первоначальный текст")
        let doomed = try makeFile("Обречённая.md", contents: "скоро удалят")
        let index = try makeIndex()
        XCTAssertEqual(try index.search("первоначальный").count, 1)

        // Изменение (сдвигаем mtime явно: APFS может дать ту же секунду).
        try "совершенно новый текст".write(to: changing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: changing.path
        )
        // Добавление и удаление.
        try makeFile("Новая.md", contents: "свежесозданная заметка")
        try FileManager.default.removeItem(at: doomed)

        XCTAssertTrue(try index.refresh(root: tempDir))

        XCTAssertEqual(try index.search("совершенно").count, 1)
        XCTAssertEqual(try index.search("первоначальный").count, 0)
        XCTAssertEqual(try index.search("свежесозданная").count, 1)
        XCTAssertEqual(try index.search("скоро").count, 0)

        // Без изменений refresh — false.
        XCTAssertFalse(try index.refresh(root: tempDir))
    }

    func testRebuildFromScratch() throws {
        try makeFile("Одна.md", contents: "альфа")
        let index = try makeIndex()
        try makeFile("Две.md", contents: "бета")

        try index.rebuild(root: tempDir)

        XCTAssertEqual(try index.search("альфа").count, 1)
        XCTAssertEqual(try index.search("бета").count, 1)
    }

    func testDotFoldersNotIndexed() throws {
        try makeFile(".obsidian/конфиг.md", contents: "служебное слово абракадабра")
        let index = try makeIndex()

        XCTAssertEqual(try index.search("абракадабра").count, 0)
    }

    func testEmptyAndPunctuationQueriesReturnNothing() throws {
        try makeFile("Заметка.md", contents: "просто текст")
        let index = try makeIndex()

        XCTAssertEqual(try index.search("").count, 0)
        XCTAssertEqual(try index.search("   ").count, 0)
        XCTAssertEqual(try index.search("!!! ???").count, 0)
    }

    func testRankingPrefersBetterMatch() throws {
        try makeFile("Много совпадений.md", contents: "тема тема тема тема тема")
        try makeFile("Одно совпадение.md", contents: String(repeating: "наполнитель ", count: 200) + "тема")
        let index = try makeIndex()

        let hits = try index.search("тема")
        XCTAssertEqual(hits.first?.title, "Много совпадений") // bm25: плотнее — выше
    }
}

// MARK: - ftsQuery

final class FTSQueryTests: XCTestCase {

    func testTokensBecomeQuotedPrefixes() {
        XCTAssertEqual(SearchIndex.ftsQuery(from: "привет мир"), "\"привет\"* \"мир\"*")
    }

    func testPunctuationStrippedAndQuotesEscaped() {
        XCTAssertEqual(SearchIndex.ftsQuery(from: "C++ и \"кавычки\"!"), "\"C\"* \"и\"* \"кавычки\"*")
    }

    func testEmptyQueryGivesNil() {
        XCTAssertNil(SearchIndex.ftsQuery(from: ""))
        XCTAssertNil(SearchIndex.ftsQuery(from: "…—!!!"))
    }
}
