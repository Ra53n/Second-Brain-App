// RagChatTests.swift — задача 14: retriever на HashingEmbedder + :memory:
// (top-K порядок, порог, токен-бюджет по границе чанка), сборка [RAG_CONTEXT]
// (подписи источников), rerank/rewrite-парсеры, wikilinks в сообщениях
// (рендер, валидация галлюцинаций, извлечение целей), миграция настроек RAG.

import XCTest
@testable import SecondBrain

// MARK: - Retriever

final class RagRetrieverTests: XCTestCase {
    private var index: RagIndex!
    private let embedder = HashingEmbedder(dimension: 128)

    override func setUpWithError() throws {
        index = try RagIndex(path: ":memory:")
        // Три «заметки» с разными темами.
        try index.replaceFile(path: "Кошки.md", mtime: 1, chunks: [chunkPair(
            "Кошки любят молоко рыбу и мурлыкать дома на диване",
            path: "Кошки.md", heading: "Кошки > Питание")])
        try index.replaceFile(path: "Машины.md", mtime: 1, chunks: [chunkPair(
            "Машины ездят по дороге у них двигатель и колёса",
            path: "Машины.md", heading: "Машины")])
        try index.replaceFile(path: "Погода.md", mtime: 1, chunks: [chunkPair(
            "Сегодня солнечно и тепло на улице хорошая погода",
            path: "Погода.md", heading: "")])
    }

    private func chunkPair(_ text: String, path: String,
                           heading: String) -> (RagChunk, [Float]) {
        let chunk = RagChunk(filePath: path, headingPath: heading,
                             lineStart: 1, lineEnd: 2, text: text)
        return (chunk, embedder.vector(for: text))
    }

    func testSearchOrdersByRelevance() async {
        let hits = await RagRetriever.search(index: index, embedder: embedder,
                                             query: "что любят кошки", topK: 3)
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits[0].stored.chunk.filePath, "Кошки.md", "релевантный — первый")
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
        XCTAssertEqual(hits[0].noteName, "Кошки")
    }

    func testSearchEmptyQueryOrEmptyIndex() async throws {
        let empty = try RagIndex(path: ":memory:")
        let noHits = await RagRetriever.search(index: empty, embedder: embedder,
                                               query: "вопрос", topK: 3)
        XCTAssertEqual(noHits.count, 0)
        let blank = await RagRetriever.search(index: index, embedder: embedder,
                                              query: "   ", topK: 3)
        XCTAssertEqual(blank.count, 0)
    }

    func testRetrieveBuildsBlockWithSourcesAndDirective() async {
        let outcome = await RagRetriever.retrieve(
            index: index, embedder: embedder,
            query: "что любят кошки", history: [],
            options: .init(topK: 2), chatProvider: nil)
        XCTAssertTrue(outcome.block.contains("[источник: [[Кошки]] · Кошки > Питание]"),
                      "чанк подписан заметкой и разделом")
        XCTAssertTrue(outcome.block.contains(RagRetriever.citationDirective),
                      "директива цитирования приложена")
        XCTAssertEqual(outcome.sources.count, 2)
        XCTAssertEqual(outcome.sources[0].noteName, "Кошки")
        XCTAssertEqual(outcome.sources[0].headingPath, "Кошки > Питание")
    }

    func testRetrieveEmptyResultGivesNotFoundDirective() async {
        // Порог 0.99 отсеет всё — модель обязана честно сказать «не нашлось».
        let outcome = await RagRetriever.retrieve(
            index: index, embedder: embedder,
            query: "квантовая хромодинамика", history: [],
            options: .init(topK: 2, minScore: 0.99), chatProvider: nil)
        XCTAssertEqual(outcome.block, RagRetriever.notFoundDirective)
        XCTAssertEqual(outcome.sources, [])
    }

    func testBuildBlockRespectsTokenBudgetAtChunkBoundary() {
        let hits = (0..<5).map { i in
            RagHit(stored: StoredRagChunk(
                id: Int64(i),
                chunk: RagChunk(filePath: "n\(i).md", headingPath: "",
                                lineStart: 1, lineEnd: 1,
                                text: String(repeating: "слово ", count: 100))), // ~600 символов
                   score: 1.0 - Float(i) * 0.1)
        }
        // Бюджет ~2 чанков (600/3 = 200 токенов на чанк + метка).
        let block = RagRetriever.buildBlock(hits: hits, budgetTokens: 450)
        XCTAssertNotNil(block)
        let included = (0..<5).filter { block!.contains("[[n\($0)]]") }.count
        XCTAssertEqual(included, 2, "бюджет режет по границе чанка")

        // Крошечный бюджет: лучший чанк включается всегда.
        let tiny = RagRetriever.buildBlock(hits: hits, budgetTokens: 1)
        XCTAssertTrue(tiny!.contains("[[n0]]"))
        XCTAssertFalse(tiny!.contains("[[n1]]"))
    }

    func testBuildBlockNilOnEmpty() {
        XCTAssertNil(RagRetriever.buildBlock(hits: [], budgetTokens: 100))
    }
}

// MARK: - Rerank / rewrite (чистые парсеры)

final class RagRerankTests: XCTestCase {

    private func hit(_ score: Float, _ text: String = "т") -> RagHit {
        RagHit(stored: StoredRagChunk(id: 0, chunk: RagChunk(
            filePath: "a.md", headingPath: "", lineStart: 1, lineEnd: 1, text: text)),
               score: score)
    }

    func testThresholdFilter() {
        let hits = [hit(0.9), hit(0.5), hit(0.2)]
        XCTAssertEqual(RagRerank.thresholdFilter(hits, minScore: 0.4).count, 2)
        XCTAssertEqual(RagRerank.thresholdFilter(hits, minScore: 0).count, 3, "0 — выключен")
        XCTAssertEqual(RagRerank.thresholdFilter(hits, minScore: 0.95).count, 0,
                       "может отсеять всех — это фича")
    }

    func testParseRerankIndices() {
        XCTAssertEqual(RagRerank.parseRerankIndices("3,1,5", candidateCount: 5), [2, 0, 4])
        XCTAssertEqual(RagRerank.parseRerankIndices("0", candidateCount: 5), [],
                       "«0» — ничего не релевантно")
        XCTAssertNil(RagRerank.parseRerankIndices("полная чушь", candidateCount: 5),
                     "мусор → nil → фолбэк по score")
        XCTAssertEqual(RagRerank.parseRerankIndices("2, 2, 9, 1", candidateCount: 3), [1, 0],
                       "дедуп и отброс вне диапазона")
    }

    func testApplyRerank() {
        let hits = [hit(0.9, "а"), hit(0.8, "б"), hit(0.7, "в")]
        XCTAssertEqual(RagRerank.applyRerank(hits: hits, indices: [2, 0], topK: 2)
            .map(\.stored.chunk.text), ["в", "а"])
        XCTAssertEqual(RagRerank.applyRerank(hits: hits, indices: nil, topK: 2)
            .map(\.stored.chunk.text), ["а", "б"], "nil → порядок по score")
        XCTAssertEqual(RagRerank.applyRerank(hits: hits, indices: [], topK: 2).count, 0)
    }

    func testParseRewrittenQuery() {
        XCTAssertEqual(RagRerank.parseRewrittenQuery("«планы на релиз 3.2»", fallback: "х"),
                       "планы на релиз 3.2", "кавычки срезаны")
        XCTAssertEqual(RagRerank.parseRewrittenQuery("Запрос: сроки релиза", fallback: "х"),
                       "сроки релиза", "служебный префикс срезан")
        XCTAssertEqual(RagRerank.parseRewrittenQuery("", fallback: "исходный"), "исходный")
        let tooLong = String(repeating: "а", count: 1000)
        XCTAssertEqual(RagRerank.parseRewrittenQuery(tooLong, fallback: "исходный"), "исходный")
    }
}

// MARK: - Wikilinks в сообщениях

final class ChatWikilinkRendererTests: XCTestCase {

    func testResolvableLinkBecomesMarkdownLink() {
        let rendered = ChatWikilinkRenderer.render("См. [[Команда]] и всё.") { $0 == "Команда" }
        XCTAssertTrue(rendered.contains("[Команда](sbwiki://open?target="))
        XCTAssertFalse(rendered.contains("[["))
    }

    func testUnresolvableLinkMarkedAsHallucination() {
        let rendered = ChatWikilinkRenderer.render("См. [[Выдумка]].") { _ in false }
        XCTAssertTrue(rendered.contains("~~Выдумка~~ ⚠︎"), "галлюцинация помечена")
        XCTAssertFalse(rendered.contains("sbwiki://"))
    }

    func testAliasUsedAsDisplayText() {
        let rendered = ChatWikilinkRenderer.render("[[Команда|наша команда]]") { _ in true }
        XCTAssertTrue(rendered.contains("[наша команда](sbwiki://"))
    }

    func testRoundTripTargetThroughURL() throws {
        let urlString = try XCTUnwrap(ChatWikilinkRenderer.url(for: "Управление командой/1на1"))
        let url = try XCTUnwrap(URL(string: urlString))
        XCTAssertEqual(ChatWikilinkRenderer.target(from: url), "Управление командой/1на1",
                       "кириллица и путь переживают percent-encoding")
        XCTAssertNil(ChatWikilinkRenderer.target(from: URL(string: "https://example.com")!))
    }

    func testTargetsExtraction() {
        let targets = ChatWikilinkRenderer.targets(in: "[[А]] текст [[Б|алиас]]")
        XCTAssertEqual(targets, ["А", "Б"])
    }

    func testPlainTextUntouched() {
        let text = "Обычный текст без ссылок."
        XCTAssertEqual(ChatWikilinkRenderer.render(text) { _ in true }, text)
    }
}

// MARK: - Миграция настроек RAG в чате

final class ChatRagConfigurationTests: XCTestCase {

    func testRagDefaultsOffAndMigration() throws {
        // Чат из задачи 12 (без RAG-полей) обязан загрузиться с выключенным RAG.
        let json = #"[{"title": "Старый", "configuration": {"temperature": 0.5}}]"#
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Data(json.utf8).write(to: tempURL)

        let loaded = ChatPersistence.load(from: tempURL)
        XCTAssertFalse(loaded[0].configuration.ragEnabled, "дефолт — выключен")
        XCTAssertEqual(loaded[0].configuration.ragTopK, 4)
        XCTAssertFalse(loaded[0].configuration.ragRerankEnabled)
        XCTAssertEqual(loaded[0].configuration.temperature, 0.5)
    }

    func testMessageSourcesPersist() throws {
        var chat = Chat()
        var message = ChatMessage(role: .assistant, content: "ответ [[Кошки]]")
        message.sources = [RagSource(noteName: "Кошки", filePath: "Кошки.md",
                                     headingPath: "Питание", score: 0.87)]
        chat.messages = [message]
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        ChatPersistence.save([chat], to: tempURL)

        let loaded = ChatPersistence.load(from: tempURL)
        XCTAssertEqual(loaded[0].messages[0].sources?.first?.noteName, "Кошки")
        XCTAssertEqual(loaded[0].messages[0].sources?.first?.score ?? 0, 0.87, accuracy: 0.001)
    }
}
