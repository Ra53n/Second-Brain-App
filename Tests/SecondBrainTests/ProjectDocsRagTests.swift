// ProjectDocsRagTests.swift — тесты RAG-индексации доков проекта и git_diff
// (задача 25): синхронизация индекса (инкрементальность, смена тега модели),
// ретрив top-K с источниками, фолбэк helpContext без эмбеддера, diff-инструмент.

import XCTest
@testable import SecondBrain

/// Детерминированный мок-эмбеддер: вектор из хешей слов — тексты с общими
/// словами ближе друг к другу, чем разные (хватает для проверки ретрива).
private final class MockEmbedder: EmbeddingProvider {
    let dimension = 8
    private(set) var embedCallCount = 0
    private(set) var embeddedTexts: [String] = []
    /// Модели, с которыми звали embed (проверка проброса, задача 28).
    private(set) var receivedModels: [String?] = []

    func embed(_ texts: [String], model: String?) async throws -> [[Float]] {
        embedCallCount += 1
        embeddedTexts += texts
        receivedModels.append(model)
        return texts.map { text in
            var vector = [Float](repeating: 0, count: dimension)
            for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
                var hash = 5381
                for scalar in word.unicodeScalars { hash = (hash &* 33) &+ Int(scalar.value) }
                vector[abs(hash) % dimension] += 1
            }
            return vector
        }
    }
}

final class ProjectDocsRagTests: XCTestCase {

    private var repoRoot: URL!
    private var indexPath: URL!
    private var service: ProjectDocsIndexService!
    private var embedder: MockEmbedder!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("docsrag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot.appendingPathComponent("docs"),
                                                withIntermediateDirectories: true)
        try "# Проект\nПриложение второй мозг для заметок."
            .write(to: repoRoot.appendingPathComponent("README.md"),
                   atomically: true, encoding: .utf8)
        try "# Хранение\nЧаты хранятся в файле chats.json в Application Support."
            .write(to: repoRoot.appendingPathComponent("docs/DATA.md"),
                   atomically: true, encoding: .utf8)
        service = ProjectDocsIndexService()
        embedder = MockEmbedder()
        indexPath = ProjectDocsIndexService.indexFileURL(repoRoot: repoRoot)
        try? FileManager.default.removeItem(at: indexPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
        try? FileManager.default.removeItem(at: indexPath.deletingLastPathComponent())
    }

    func testRetrieveReturnsRelevantChunkWithSource() async {
        let block = await service.helpBlock(repoRoot: repoRoot, embedder: embedder,
                                            model: nil,
                                            tag: "mock|8",
                                            question: "где хранятся чаты chats.json",
                                            topK: 1)
        XCTAssertNotNil(block)
        XCTAssertTrue(block?.contains("chats.json") == true, block ?? "nil")
        XCTAssertTrue(block?.contains("docs/DATA.md") == true, "источник в разделителе: \(block ?? "nil")")
    }

    /// Повторный вызов без изменений файлов не переэмбеддит (инкрементальность).
    func testIncrementalSyncSkipsUnchangedFiles() async {
        _ = await service.helpBlock(repoRoot: repoRoot, embedder: embedder,
                                    model: nil,
                                    tag: "mock|8", question: "вопрос")
        let callsAfterFirst = embedder.embedCallCount

        _ = await service.helpBlock(repoRoot: repoRoot, embedder: embedder,
                                    model: nil,
                                    tag: "mock|8", question: "другой вопрос")
        // +1 вызов — только эмбеддинг вопроса, файлы не пересчитываются.
        XCTAssertEqual(embedder.embedCallCount, callsAfterFirst + 1)
    }

    /// Смена тега модели → полная переиндексация (векторы несовместимы).
    func testTagChangeForcesFullReindex() async {
        _ = await service.helpBlock(repoRoot: repoRoot, embedder: embedder,
                                    model: nil,
                                    tag: "old|8", question: "вопрос")
        let before = embedder.embeddedTexts.count

        _ = await service.helpBlock(repoRoot: repoRoot, embedder: embedder,
                                    model: nil,
                                    tag: "new|8", question: "вопрос")
        // Все чанки эмбеддятся заново (+ вопрос).
        XCTAssertGreaterThan(embedder.embeddedTexts.count, before + 1)
    }

    /// Изменение файла переиндексирует только его; удалённый файл уходит из индекса.
    func testChangedFileReindexedAndDeletedRemoved() async throws {
        _ = await service.helpBlock(repoRoot: repoRoot, embedder: embedder,
                                    model: nil,
                                    tag: "mock|8", question: "вопрос")

        // Меняем README (mtime в прошлое не выставляем — контент+mtime новые).
        try "# Проект\nТеперь тут написано про синхронизацию git."
            .write(to: repoRoot.appendingPathComponent("README.md"),
                   atomically: true, encoding: .utf8)
        // Удаляем docs/DATA.md.
        try FileManager.default.removeItem(at: repoRoot.appendingPathComponent("docs/DATA.md"))

        let block = await service.helpBlock(repoRoot: repoRoot, embedder: embedder,
                                            model: nil,
                                            tag: "mock|8",
                                            question: "где хранятся чаты chats.json",
                                            topK: 3)
        XCTAssertTrue(block?.contains("chats.json") != true,
                      "удалённый файл не должен находиться: \(block ?? "nil")")
        XCTAssertTrue(block?.contains("синхронизацию") == true, block ?? "nil")
    }

    /// Задача 28: модель эмбеддинга доходит до эмбеддера доков.
    func testHelpBlockPassesModelToEmbedder() async {
        _ = await service.helpBlock(repoRoot: repoRoot, embedder: embedder,
                                    model: "custom-embed",
                                    tag: "custom-embed|8", question: "вопрос")
        XCTAssertFalse(embedder.receivedModels.isEmpty)
        XCTAssertTrue(embedder.receivedModels.allSatisfy { $0 == "custom-embed" },
                      "\(embedder.receivedModels)")
    }

    /// Задача 31: ретрив для источника «Проект» несёт источники с оценками.
    func testRetrievalOutcomeCarriesSources() async {
        let outcome = await service.retrievalOutcome(repoRoot: repoRoot,
                                                     embedder: embedder,
                                                     model: nil,
                                                     tag: "mock|8",
                                                     question: "где хранятся чаты chats.json",
                                                     topK: 2)
        XCTAssertNotNil(outcome)
        XCTAssertTrue(outcome?.block.contains("chats.json") == true)
        XCTAssertFalse(outcome?.sources.isEmpty ?? true)
        XCTAssertTrue(outcome?.sources.contains { $0.filePath == "docs/DATA.md" } == true,
                      "\(outcome?.sources.map(\.filePath) ?? [])")
    }

    /// Задача 28: stats nil до первой индексации, заполнен после; reset обнуляет.
    func testStatsAndReset() async {
        let statsBefore = await service.stats(repoRoot: repoRoot)
        XCTAssertNil(statsBefore, "индекс ещё не строился")

        _ = await service.helpBlock(repoRoot: repoRoot, embedder: embedder,
                                    model: nil,
                                    tag: "mock|8", question: "вопрос")
        let stats = await service.stats(repoRoot: repoRoot)
        XCTAssertEqual(stats?.files, 2)
        XCTAssertGreaterThan(stats?.chunks ?? 0, 0)
        XCTAssertNotNil(stats?.updatedAt)

        await service.reset(repoRoot: repoRoot)
        let statsAfter = await service.stats(repoRoot: repoRoot)
        XCTAssertEqual(statsAfter?.chunks, 0)
    }

    /// helpContext без роутера (нет эмбеддера) — фолбэк на полный контекст.
    @MainActor
    func testHelpContextFallsBackToFullDocsWithoutEmbedder() async throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("docsrag-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let store = SettingsStore(fileURL: settingsURL)
        store.settings.projectRepoPath = repoRoot.path

        let provider = ProjectToolsProvider(settingsStore: store, router: nil)
        let context = await provider.helpContext(question: "где хранятся чаты?")
        XCTAssertTrue(context?.contains("=== README.md ===") == true,
                      "полный контекст с README: \(context?.prefix(120) ?? "nil")")
        XCTAssertTrue(context?.contains("chats.json") == true)
    }

    /// Без выбранного репозитория helpContext возвращает nil.
    @MainActor
    func testHelpContextNilWithoutRepo() async throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("docsrag-settings2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let provider = ProjectToolsProvider(settingsStore: SettingsStore(fileURL: settingsURL))
        let context = await provider.helpContext(question: "вопрос")
        XCTAssertNil(context)
    }
}

// MARK: - git_diff

final class GitDiffToolTests: XCTestCase {

    private var repoRoot: URL!
    private var executor: ToolExecutor!

    override func setUp() async throws {
        try XCTSkipIf(GitClient.detectGitPath() == nil, "git не найден")
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitdiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let client = GitClient(repoURL: repoRoot)
        try await client.initRepository()
        try await client.configSet("user.name", "Test")
        try await client.configSet("user.email", "test@example.com")
        try await client.configSet("commit.gpgsign", "false")
        try "строка один\n".write(to: repoRoot.appendingPathComponent("file.md"),
                                  atomically: true, encoding: .utf8)
        _ = try await client.commitAll(message: "база")
        executor = ToolExecutor(registry: ToolRegistry.projectTools(repoRoot: repoRoot),
                                repoRoot: repoRoot)
    }

    override func tearDown() {
        if let repoRoot { try? FileManager.default.removeItem(at: repoRoot) }
    }

    func testCleanRepoReportsNoChanges() async {
        let result = await executor.execute(name: "git_diff", argumentsJSON: "{}")
        XCTAssertTrue(result.contains("Незакоммиченных изменений нет"), result)
    }

    func testDiffShowsModification() async throws {
        try "строка один\nстрока два\n".write(to: repoRoot.appendingPathComponent("file.md"),
                                              atomically: true, encoding: .utf8)
        let result = await executor.execute(name: "git_diff", argumentsJSON: "{}")
        XCTAssertTrue(result.contains("+строка два"), result)

        let filtered = await executor.execute(name: "git_diff",
                                              argumentsJSON: #"{"path":"file.md"}"#)
        XCTAssertTrue(filtered.contains("+строка два"), filtered)

        let escape = await executor.execute(name: "git_diff",
                                            argumentsJSON: #"{"path":"../x"}"#)
        XCTAssertTrue(escape.hasPrefix("ERROR:"), escape)
    }
}
