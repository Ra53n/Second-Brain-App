// RagToolTests.swift — тесты задачи 34: rag_search как инструмент модели.
//
// Покрытие по критериям приёмки:
//  - definition: валидная object-схема, query обязателен, enum по именам
//    включённых баз (уникализация дубликатов), один инструмент без «__»;
//  - parseArguments: пустой query, неизвестная база, база не указана;
//  - formatResult: разделители с базой-источником, токен-бюджет по границе
//    чанка, anti-injection оговорка, честное «не нашлось»;
//  - KnowledgeMerge: сортировка по score между базами, дедуп, глобальный
//    topK, notFoundDirective при пустом входе.

import XCTest
@testable import SecondBrain

// MARK: - Фикстуры

private func hit(base: String = "vault", baseName: String = "Vault",
                 path: String = "Заметка.md", heading: String = "Раздел",
                 text: String = "текст", score: Double = 0.5) -> KnowledgeHit {
    KnowledgeHit(baseID: base, baseName: baseName, filePath: path,
                 headingPath: heading, text: text, score: score)
}

// MARK: - Определение инструмента

final class RagSearchToolDefinitionTests: XCTestCase {

    private let bases = [
        KnowledgeBase.builtinVault(),
        KnowledgeBase.builtinProject(),
        KnowledgeBase(id: "f1", kind: .folder, name: "Рецепты", path: "/tmp/r")
    ]

    func testDefinitionSchemaAndName() throws {
        let definition = try XCTUnwrap(RagSearchTool.definition(bases: bases))
        XCTAssertEqual(definition.name, "rag_search")
        XCTAssertFalse(definition.name.contains("__"),
                       "без «__» — нет коллизий с qualified-именами MCP")
        // Схема — объект с обязательным query и enum имён баз в base.
        XCTAssertEqual(definition.schema["type"]?.stringValue, "object")
        XCTAssertEqual(definition.schema["required"]?.arrayValue?.first?.stringValue,
                       "query")
        let baseEnum = definition.schema["properties"]?["base"]?["enum"]?.arrayValue?
            .compactMap(\.stringValue)
        XCTAssertEqual(baseEnum, ["Vault", "Проект", "Рецепты"])
        // Каталог баз перечислен в описании — модель знает, где что лежит.
        XCTAssertTrue(definition.description.contains("«Рецепты»"))
    }

    func testNoBasesGivesNil() {
        XCTAssertNil(RagSearchTool.definition(bases: []))
    }

    /// Одна база — параметр base не нужен (выбирать не из чего).
    func testSingleBaseHasNoBaseParameter() throws {
        let definition = try XCTUnwrap(
            RagSearchTool.definition(bases: [KnowledgeBase.builtinVault()]))
        XCTAssertNil(definition.schema["properties"]?["base"])
    }

    /// Дубликаты имён уникализируются суффиксом — enum однозначен.
    func testDuplicateNamesUniquified() {
        let duplicates = [
            KnowledgeBase(id: "a", kind: .folder, name: "Заметки", path: "/a"),
            KnowledgeBase(id: "b", kind: .folder, name: "Заметки", path: "/b")
        ]
        let names = RagSearchTool.uniqueNames(duplicates).map(\.name)
        XCTAssertEqual(names, ["Заметки", "Заметки (2)"])
    }
}

// MARK: - Разбор аргументов

final class RagSearchToolParseTests: XCTestCase {

    private let bases = [
        KnowledgeBase.builtinVault(),
        KnowledgeBase(id: "f1", kind: .folder, name: "Рецепты", path: "/tmp/r")
    ]

    func testQueryOnlySearchesAllBases() {
        let parsed = RagSearchTool.parseArguments(#"{"query":"борщ"}"#, bases: bases)
        XCTAssertEqual(parsed, .success(query: "борщ", baseID: nil))
    }

    func testBaseNameResolvesToID() {
        let parsed = RagSearchTool.parseArguments(
            #"{"query":"борщ","base":"Рецепты"}"#, bases: bases)
        XCTAssertEqual(parsed, .success(query: "борщ", baseID: "f1"))
    }

    func testMissingQueryFails() {
        guard case .failure(let message) =
                RagSearchTool.parseArguments(#"{"base":"Vault"}"#, bases: bases) else {
            return XCTFail("нет query — ошибка")
        }
        XCTAssertTrue(message.contains("query"))
    }

    func testUnknownBaseFailsAndListsKnown() {
        guard case .failure(let message) = RagSearchTool.parseArguments(
            #"{"query":"q","base":"Чужая"}"#, bases: bases) else {
            return XCTFail("неизвестная база — ошибка")
        }
        XCTAssertTrue(message.contains("«Чужая»"))
        XCTAssertTrue(message.contains("«Рецепты»"), "перечисляем доступные")
    }

    func testBrokenJSONFailsAsMissingQuery() {
        guard case .failure = RagSearchTool.parseArguments("не json", bases: bases) else {
            return XCTFail("битые аргументы — ошибка, не падение")
        }
    }
}

// MARK: - Форматирование результата

final class RagSearchToolFormatTests: XCTestCase {

    func testFormatCarriesSourcesAndAntiInjection() {
        let result = RagSearchTool.formatResult(hits: [
            hit(baseName: "Vault", path: "Кошки.md", heading: "Питание",
                text: "Кошки любят молоко", score: 0.9),
            hit(base: "f1", baseName: "Рецепты", path: "Борщ.md", heading: "",
                text: "Борщ варится два часа", score: 0.7)
        ])
        XCTAssertTrue(result.text.contains("=== [Vault] Кошки.md · Питание ==="))
        XCTAssertTrue(result.text.contains("=== [Рецепты] Борщ.md ==="))
        XCTAssertTrue(result.text.contains("СПРАВОЧНЫЕ ДАННЫЕ"),
                      "anti-injection оговорка обязательна")
        XCTAssertTrue(result.text.contains("[[Имя заметки]]"),
                      "просьба цитировать wikilink'ами")
        XCTAssertEqual(result.included.count, 2)
    }

    /// Бюджет режет по границе чанка; первый (лучший) включается всегда.
    func testBudgetCutsAtChunkBoundary() {
        let long = String(repeating: "слово ", count: 400) // ~2400 символов
        let result = RagSearchTool.formatResult(
            hits: [hit(text: long, score: 0.9),
                   hit(path: "Вторая.md", text: long, score: 0.8)],
            budgetTokens: 900)
        XCTAssertEqual(result.included.count, 1, "второй чанк не влез в бюджет")
        XCTAssertTrue(result.text.contains("Заметка.md"))
        XCTAssertFalse(result.text.contains("Вторая.md"))
    }

    func testEmptyHitsGiveHonestNotFound() {
        let result = RagSearchTool.formatResult(hits: [])
        XCTAssertTrue(result.text.contains("Ничего не найдено"))
        XCTAssertTrue(result.included.isEmpty)
    }
}

// MARK: - Слияние баз

final class KnowledgeMergeTests: XCTestCase {

    func testMergeSortsAcrossBasesByScore() {
        let merged = KnowledgeMerge.dedupSorted(hitsPerBase: [
            [hit(path: "A.md", score: 0.3), hit(path: "B.md", score: 0.9)],
            [hit(base: "f1", baseName: "Рецепты", path: "C.md", score: 0.6)]
        ], topK: 3)
        XCTAssertEqual(merged.map(\.filePath), ["B.md", "C.md", "A.md"],
                       "шкала score общая — сортировка сквозная")
    }

    func testMergeDedupsAndCapsAtTopK() {
        let merged = KnowledgeMerge.dedupSorted(hitsPerBase: [
            [hit(path: "A.md", score: 0.9), hit(path: "A.md", score: 0.8)],
            [hit(path: "B.md", score: 0.7), hit(path: "C.md", score: 0.6)]
        ], topK: 2)
        XCTAssertEqual(merged.map(\.filePath), ["A.md", "B.md"],
                       "дубликат отброшен, глобальный topK = 2")
    }

    func testMergeBuildsBlockWithBaseLabelsAndDirective() {
        let outcome = KnowledgeMerge.merge(hitsPerBase: [
            [hit(path: "Кошки.md", heading: "Питание",
                 text: "Кошки любят молоко", score: 0.9)],
            [hit(base: "f1", baseName: "Рецепты", path: "Борщ.md", heading: "",
                 text: "Борщ варится два часа", score: 0.7)]
        ], topK: 4)
        XCTAssertTrue(outcome.block.contains("[[Кошки]] · Питание — база «Vault»"))
        XCTAssertTrue(outcome.block.contains("[[Борщ]] — база «Рецепты»"))
        XCTAssertTrue(outcome.block.contains(RagRetriever.citationDirective),
                      "одна директива цитирования на весь блок")
        XCTAssertEqual(outcome.sources.map(\.noteName), ["Кошки", "Борщ"])
    }

    func testMergeEmptyGivesNotFoundDirective() {
        let outcome = KnowledgeMerge.merge(hitsPerBase: [[], []], topK: 4)
        XCTAssertEqual(outcome.block, RagRetriever.notFoundDirective)
        XCTAssertTrue(outcome.sources.isEmpty)
    }
}
