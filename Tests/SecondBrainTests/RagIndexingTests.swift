// RagIndexingTests.swift — задача 13: структурный чанкер (кириллица,
// код-блоки, пустые файлы, пути заголовков, диапазоны строк), SQLite-индекс
// round-trip на :memory:, инкрементальная синхронизация на temp-vault
// (изменение/удаление/добавление), инвалидация при смене модели эмбеддинга.
// Всё офлайн — HashingEmbedder (детерминированный, порт из MA уже в LLM/).

import XCTest
@testable import SecondBrain

// MARK: - Чанкер

final class MarkdownChunkerTests: XCTestCase {

    func testEmptyFileGivesNoChunks() {
        XCTAssertEqual(MarkdownChunker.chunk(text: "", filePath: "a.md"), [])
        XCTAssertEqual(MarkdownChunker.chunk(text: "  \n\n  ", filePath: "a.md"), [])
    }

    func testSplitsByHeadingsWithCyrillicPath() {
        let text = """
        # Управление командой
        Общие принципы.

        ## Один на один
        Раз в неделю, 30 минут.

        ## Ретроспективы
        Раз в спринт.
        """
        let chunks = MarkdownChunker.chunk(text: text, filePath: "Команда.md")
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].headingPath, "Управление командой")
        XCTAssertEqual(chunks[1].headingPath, "Управление командой > Один на один",
                       "путь заголовков H1 > H2")
        XCTAssertEqual(chunks[2].headingPath, "Управление командой > Ретроспективы")
        XCTAssertTrue(chunks[1].text.contains("Раз в неделю"))
        XCTAssertEqual(chunks[0].filePath, "Команда.md")
    }

    func testHeadingStackResetsOnHigherLevel() {
        let text = "# А\nа\n## Б\nб\n# В\nв"
        let chunks = MarkdownChunker.chunk(text: text, filePath: "x.md")
        XCTAssertEqual(chunks.map(\.headingPath), ["А", "А > Б", "В"],
                       "новый H1 сбрасывает стек")
    }

    func testHeadingsInsideCodeFencesIgnored() {
        let text = """
        # Настоящий заголовок
        Текст до кода.
        ```bash
        # это комментарий в коде, не заголовок
        echo hi
        ```
        Текст после кода.
        """
        let chunks = MarkdownChunker.chunk(text: text, filePath: "code.md")
        XCTAssertEqual(chunks.count, 1, "заголовок внутри ``` не создаёт раздел")
        XCTAssertTrue(chunks[0].text.contains("это комментарий"))
    }

    func testPreambleBeforeFirstHeadingHasEmptyPath() {
        let text = "Преамбула без заголовка.\n\n# Раздел\nТело."
        let chunks = MarkdownChunker.chunk(text: text, filePath: "p.md")
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].headingPath, "")
        XCTAssertEqual(chunks[0].lineStart, 1)
    }

    func testLineRanges() {
        let text = "# А\nстрока 2\nстрока 3\n# Б\nстрока 5"
        let chunks = MarkdownChunker.chunk(text: text, filePath: "l.md")
        XCTAssertEqual(chunks[0].lineStart, 1)
        XCTAssertEqual(chunks[0].lineEnd, 3)
        XCTAssertEqual(chunks[1].lineStart, 4)
        XCTAssertEqual(chunks[1].lineEnd, 5)
    }

    func testLongSectionSplitRetainsHeadingPath() {
        let body = (1...100).map { "строка номер \($0) с достаточно длинным текстом" }
            .joined(separator: "\n")
        let text = "# Длинный\n" + body
        let chunks = MarkdownChunker.chunk(text: text, filePath: "long.md", maxChars: 500)
        XCTAssertGreaterThan(chunks.count, 1, "длинный раздел дорезан")
        for chunk in chunks {
            XCTAssertEqual(chunk.headingPath, "Длинный")
            XCTAssertLessThanOrEqual(chunk.text.count, 600) // maxChars + запас строки
        }
        // Диапазоны строк непрерывны и не перекрываются.
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(pair.1.lineStart, pair.0.lineEnd + 1)
        }
    }

    func testNoHeadingsSingleChunk() {
        let text = "Просто текст\nбез заголовков."
        let chunks = MarkdownChunker.chunk(text: text, filePath: "plain.md")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].headingPath, "")
    }
}

// MARK: - SQLite-индекс

final class RagIndexTests: XCTestCase {

    private func makeChunk(_ text: String, path: String = "a.md") -> RagChunk {
        RagChunk(filePath: path, headingPath: "H1 > H2", lineStart: 1, lineEnd: 3, text: text)
    }

    func testReplaceFileRoundTrip() throws {
        let index = try RagIndex(path: ":memory:")
        let vector: [Float] = [0.25, -1.5, 3.125, 0]
        try index.replaceFile(path: "a.md", mtime: 123.456,
                              chunks: [(makeChunk("привет"), vector)])

        let (chunks, vectors) = try index.loadAll()
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].chunk.text, "привет")
        XCTAssertEqual(chunks[0].chunk.headingPath, "H1 > H2")
        XCTAssertEqual(chunks[0].chunk.lineStart, 1)
        XCTAssertEqual(vectors[0], vector, "вектор восстановлен бит-в-бит (Float32 LE)")
        XCTAssertEqual(try index.fileMtimes()["a.md"] ?? 0, 123.456, accuracy: 0.001)
    }

    func testReplaceFileOverwritesOldChunks() throws {
        let index = try RagIndex(path: ":memory:")
        try index.replaceFile(path: "a.md", mtime: 1, chunks: [
            (makeChunk("старый 1"), [1]), (makeChunk("старый 2"), [2])
        ])
        try index.replaceFile(path: "a.md", mtime: 2, chunks: [(makeChunk("новый"), [3])])

        let (chunks, _) = try index.loadAll()
        XCTAssertEqual(chunks.map(\.chunk.text), ["новый"], "старые чанки файла удалены")
        XCTAssertEqual(try index.stats().files, 1)
    }

    func testRemoveFileDeletesChunks() throws {
        let index = try RagIndex(path: ":memory:")
        try index.replaceFile(path: "a.md", mtime: 1, chunks: [(makeChunk("а"), [1])])
        try index.replaceFile(path: "b.md", mtime: 1,
                              chunks: [(makeChunk("б", path: "b.md"), [2])])
        try index.removeFile(path: "a.md")

        let (chunks, _) = try index.loadAll()
        XCTAssertEqual(chunks.map(\.chunk.filePath), ["b.md"])
        XCTAssertNil(try index.fileMtimes()["a.md"])
    }

    func testEmbeddingTagAndClearAll() throws {
        let index = try RagIndex(path: ":memory:")
        XCTAssertNil(index.embeddingTag)
        index.embeddingTag = "nomic|768"
        XCTAssertEqual(index.embeddingTag, "nomic|768")
        try index.replaceFile(path: "a.md", mtime: 1, chunks: [(makeChunk("x"), [1])])
        try index.clearAll()
        XCTAssertNil(index.embeddingTag)
        XCTAssertEqual(try index.stats().chunks, 0)
    }

    func testFileWithNoChunksStillTracked() throws {
        // Пустая заметка: mtime фиксируется, чтобы не перечитывать каждый проход.
        let index = try RagIndex(path: ":memory:")
        try index.replaceFile(path: "empty.md", mtime: 5, chunks: [])
        let stats = try index.stats()
        XCTAssertEqual(stats.files, 1)
        XCTAssertEqual(stats.chunks, 0)
        XCTAssertNotNil(try index.fileMtimes()["empty.md"])
    }
}

// MARK: - Инкрементальный пайплайн

/// Эмбеддер-обёртка: считает вызовы (для проверки «ничего не пересчитано»).
private final class CountingEmbedder: EmbeddingProvider {
    private let inner = HashingEmbedder(dimension: 64)
    private(set) var embedCallCount = 0
    private(set) var embeddedTexts: [String] = []

    var dimension: Int { inner.dimension }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        embedCallCount += 1
        embeddedTexts.append(contentsOf: texts)
        return try await inner.embed(texts)
    }
}

final class RagIndexerTests: XCTestCase {
    var vaultDir: URL!

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    @discardableResult
    private func write(_ relative: String, _ content: String,
                       mtime: Date? = nil) throws -> URL {
        let url = vaultDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    func testScanVaultExcludesRecordingsDotAndNonMarkdown() throws {
        try write("Заметка.md", "# А\nтекст")
        try write("Проекты/Идея.md", "текст")
        try write("Meetings/_recordings/2026.md", "не индексировать")
        try write("картинка.png", "бинарь")
        try write(".obsidian/config.md", "скрытое")
        try write("Черновики/тайное.md", "игнор-лист")

        let files = RagIndexer.scanVault(vaultDir, ignore: ["Черновики"])
        XCTAssertEqual(Set(files.keys), ["Заметка.md", "Проекты/Идея.md"])
    }

    func testFullThenIncrementalSync() async throws {
        try write("а.md", "# Кошки\nКошки любят молоко и мурлыкать.")
        try write("б.md", "# Машины\nМашины ездят по дорогам.")
        let index = try RagIndex(path: ":memory:")
        let embedder = CountingEmbedder()

        // Полная индексация.
        var result = try await RagIndexer.sync(vaultURL: vaultDir, index: index,
                                               embedder: embedder, embeddingTag: "hash|64")
        XCTAssertEqual(result.indexedFiles, 2)
        XCTAssertEqual(try index.stats().files, 2)
        XCTAssertEqual(index.embeddingTag, "hash|64")
        XCTAssertNotNil(index.updatedAt)
        let callsAfterFull = embedder.embedCallCount

        // Повторный прогон: ничего не изменилось — эмбеддер не дёргается.
        result = try await RagIndexer.sync(vaultURL: vaultDir, index: index,
                                           embedder: embedder, embeddingTag: "hash|64")
        XCTAssertEqual(result.indexedFiles, 0)
        XCTAssertEqual(result.skippedFiles, 2)
        XCTAssertEqual(embedder.embedCallCount, callsAfterFull, "готовое не пересчитывается")

        // Правка одной заметки → переиндексирована только она.
        try write("а.md", "# Кошки\nКошки теперь любят и рыбу.",
                  mtime: Date().addingTimeInterval(10))
        result = try await RagIndexer.sync(vaultURL: vaultDir, index: index,
                                           embedder: embedder, embeddingTag: "hash|64")
        XCTAssertEqual(result.indexedFiles, 1)
        XCTAssertTrue(embedder.embeddedTexts.suffix(2).contains { $0.contains("рыбу") })

        // Удаление заметки → её чанки удалены.
        try FileManager.default.removeItem(at: vaultDir.appendingPathComponent("б.md"))
        result = try await RagIndexer.sync(vaultURL: vaultDir, index: index,
                                           embedder: embedder, embeddingTag: "hash|64")
        XCTAssertEqual(result.removedFiles, 1)
        let (chunks, _) = try index.loadAll()
        XCTAssertFalse(chunks.contains { $0.chunk.filePath == "б.md" })

        // Добавление новой заметки.
        try write("в.md", "# Птицы\nПтицы летают.")
        result = try await RagIndexer.sync(vaultURL: vaultDir, index: index,
                                           embedder: embedder, embeddingTag: "hash|64")
        XCTAssertEqual(result.indexedFiles, 1)
        XCTAssertEqual(try index.stats().files, 2)
    }

    func testEmbeddingModelChangeThrowsInvalidation() async throws {
        try write("а.md", "# Т\nтекст")
        let index = try RagIndex(path: ":memory:")
        let embedder = CountingEmbedder()
        try await RagIndexer.sync(vaultURL: vaultDir, index: index,
                                  embedder: embedder, embeddingTag: "старая|64")

        do {
            try await RagIndexer.sync(vaultURL: vaultDir, index: index,
                                      embedder: embedder, embeddingTag: "новая|768")
            XCTFail("ожидалась инвалидация индекса")
        } catch let error as RagError {
            XCTAssertEqual(error, .embeddingModelChanged(indexTag: "старая|64",
                                                         currentTag: "новая|768"))
        }
        // После полной очистки — новая модель индексирует заново.
        try index.clearAll()
        let result = try await RagIndexer.sync(vaultURL: vaultDir, index: index,
                                               embedder: embedder, embeddingTag: "новая|768")
        XCTAssertEqual(result.indexedFiles, 1)
        XCTAssertEqual(index.embeddingTag, "новая|768")
    }

    func testSearchFindsRelevantChunkAfterIndexing() async throws {
        // Смоук поверх индекса: топ-1 по косинусу — «кошачий» чанк.
        try write("кошки.md", "# Кошки\nКошки любят молоко рыбу и мурлыкать дома.")
        try write("машины.md", "# Машины\nМашины ездят по дороге, у них двигатель и колёса.")
        let index = try RagIndex(path: ":memory:")
        let embedder = CountingEmbedder()
        try await RagIndexer.sync(vaultURL: vaultDir, index: index,
                                  embedder: embedder, embeddingTag: "hash|64")

        let (chunks, vectors) = try index.loadAll()
        let query = try await embedder.embed(["что любят кошки"])[0]
        let hits = Vector.topK(query: query, matrix: vectors, k: 1)
        XCTAssertEqual(chunks[hits[0].index].chunk.filePath, "кошки.md")
    }

    func testPlanComparesMtimes() {
        let plan = RagIndexer.plan(
            vaultFiles: ["a.md": 100, "b.md": 200, "new.md": 50],
            indexedFiles: ["a.md": 100, "b.md": 150, "gone.md": 10])
        XCTAssertEqual(plan.update, ["b.md", "new.md"])
        XCTAssertEqual(plan.remove, ["gone.md"])
    }
}
