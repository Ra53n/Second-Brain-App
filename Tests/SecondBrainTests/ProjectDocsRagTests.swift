// ProjectDocsRagTests.swift — тесты RAG-индексации доков проекта и git_diff
// (задача 25): синхронизация индекса (инкрементальность, смена тега модели),
// ретрив top-K с источниками, фолбэк helpContext без эмбеддера, diff-инструмент.

import XCTest
@testable import SecondBrain

/// Эмбеддер, всегда падающий с ошибкой — проверка проброса ошибки rebuild (задача 47).
private final class FailingEmbedder: EmbeddingProvider {
    let dimension = 8
    func embed(_ texts: [String], model: String?) async throws -> [[Float]] {
        throw LLMError.providerUnavailable(ProviderID("openai"))
    }
}

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
        XCTAssertEqual(stats?.embeddingTag, "mock|8")

        await service.reset(repoRoot: repoRoot)
        let statsAfter = await service.stats(repoRoot: repoRoot)
        XCTAssertEqual(statsAfter?.chunks, 0)
    }

    /// Задача 47: кнопка «Перестроить индекс» — reset + полная переиндексация
    /// без вопроса; после rebuild цифры снова заполнены.
    func testRebuildResetsThenReindexesFully() async throws {
        _ = await service.helpBlock(repoRoot: repoRoot, embedder: embedder,
                                    model: nil, tag: "mock|8", question: "вопрос")
        let before = await service.stats(repoRoot: repoRoot)
        XCTAssertGreaterThan(before?.chunks ?? 0, 0)
        let callsBefore = embedder.embedCallCount

        try await service.rebuild(repoRoot: repoRoot, embedder: embedder, model: nil, tag: "mock|8")

        let after = await service.stats(repoRoot: repoRoot)
        XCTAssertGreaterThan(after?.chunks ?? 0, 0, "индекс перестроен")
        XCTAssertGreaterThan(embedder.embedCallCount, callsBefore,
                             "rebuild переэмбеддил файлы заново, а не пропустил как неизменённые")
    }

    /// Задача 47 (важное 1 ревью): ошибка эмбеддера по кнопке — явное действие
    /// пользователя, rebuild её не глотает, а пробрасывает вызывающему (P6).
    func testRebuildPropagatesEmbeddingError() async {
        do {
            try await service.rebuild(repoRoot: repoRoot, embedder: FailingEmbedder(),
                                      model: nil, tag: "mock|8")
            XCTFail("ожидалась ошибка эмбеддера")
        } catch {
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
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

// MARK: - Статус секции «Документация проекта» (задача 47)

final class ProjectDocsIndexUIStatusTests: XCTestCase {

    private let builtStats = ProjectDocsIndexService.DocsIndexStats(
        files: 12, chunks: 84, updatedAt: Date(timeIntervalSince1970: 0),
        embeddingTag: "text-embedding-3-small|1536")

    /// Все восемь сочетаний «репо / индекс / эмбеддер» дают предсказуемый
    /// кейс и доступность кнопки «Перестроить индекс».
    func testAllCombinations() {
        struct Case {
            let hasRepo: Bool
            let hasEmbedder: Bool
            let stats: ProjectDocsIndexService.DocsIndexStats?
            let expected: ProjectDocsIndexUIStatus
            let name: String
        }
        let cases: [Case] = [
            Case(hasRepo: false, hasEmbedder: false, stats: nil,
                 expected: .noRepo, name: "нет репо, нет эмбеддера, нет индекса"),
            Case(hasRepo: false, hasEmbedder: true, stats: nil,
                 expected: .noRepo, name: "нет репо, есть эмбеддер, нет индекса"),
            Case(hasRepo: false, hasEmbedder: false, stats: builtStats,
                 expected: .noRepo, name: "нет репо, есть индекс (не должно бывать, но не падаем)"),
            Case(hasRepo: false, hasEmbedder: true, stats: builtStats,
                 expected: .noRepo, name: "нет репо, всё остальное есть"),
            Case(hasRepo: true, hasEmbedder: false, stats: nil,
                 expected: .notBuilt(embedderAvailable: false),
                 name: "есть репо, нет эмбеддера, индекс не строился"),
            Case(hasRepo: true, hasEmbedder: true, stats: nil,
                 expected: .notBuilt(embedderAvailable: true),
                 name: "есть репо, есть эмбеддер, индекс не строился"),
            Case(hasRepo: true, hasEmbedder: false, stats: builtStats,
                 expected: .built(statusLine: "12 файлов · 84 чанков · text-embedding-3-small|1536 · обновлён "
                                   + DateFormatter.docsStatsFormatterForTest.string(from: builtStats.updatedAt!),
                                  embedderAvailable: false),
                 name: "есть репо и индекс, эмбеддер пропал"),
            Case(hasRepo: true, hasEmbedder: true, stats: builtStats,
                 expected: .built(statusLine: "12 файлов · 84 чанков · text-embedding-3-small|1536 · обновлён "
                                   + DateFormatter.docsStatsFormatterForTest.string(from: builtStats.updatedAt!),
                                  embedderAvailable: true),
                 name: "есть репо, эмбеддер и индекс — готово")
        ]
        for c in cases {
            let actual = ProjectDocsIndexUIStatus.classify(hasRepo: c.hasRepo,
                                                            hasEmbedder: c.hasEmbedder,
                                                            stats: c.stats)
            XCTAssertEqual(actual, c.expected, c.name)
        }
    }

    func testRebuildDisabledWithoutRepoOrEmbedder() {
        XCTAssertTrue(ProjectDocsIndexUIStatus.noRepo.rebuildDisabled)
        XCTAssertTrue(ProjectDocsIndexUIStatus.notBuilt(embedderAvailable: false).rebuildDisabled)
        XCTAssertFalse(ProjectDocsIndexUIStatus.notBuilt(embedderAvailable: true).rebuildDisabled)
        XCTAssertTrue(ProjectDocsIndexUIStatus.built(statusLine: "x", embedderAvailable: false).rebuildDisabled)
        XCTAssertFalse(ProjectDocsIndexUIStatus.built(statusLine: "x", embedderAvailable: true).rebuildDisabled)
    }

    func testUnavailableReasonText() {
        XCTAssertEqual(ProjectDocsIndexUIStatus.noRepo.unavailableReason, "репозиторий проекта не выбран")
        XCTAssertEqual(ProjectDocsIndexUIStatus.notBuilt(embedderAvailable: false).unavailableReason,
                       "нет провайдера эмбеддингов: запустите Ollama или добавьте ключ")
        XCTAssertEqual(ProjectDocsIndexUIStatus.built(statusLine: "x", embedderAvailable: false).unavailableReason,
                       "нет провайдера эмбеддингов: запустите Ollama или добавьте ключ")
        XCTAssertNil(ProjectDocsIndexUIStatus.notBuilt(embedderAvailable: true).unavailableReason)
        XCTAssertNil(ProjectDocsIndexUIStatus.built(statusLine: "x", embedderAvailable: true).unavailableReason)
    }

    /// Без даты обновления (теоретически не бывает у построенного индекса,
    /// но stats.updatedAt — Optional) строка не ломается лишним разделителем.
    func testStatusLineWithoutUpdatedAt() {
        let stats = ProjectDocsIndexService.DocsIndexStats(files: 3, chunks: 5,
                                                            updatedAt: nil, embeddingTag: nil)
        let status = ProjectDocsIndexUIStatus.classify(hasRepo: true, hasEmbedder: true, stats: stats)
        XCTAssertEqual(status, .built(statusLine: "3 файлов · 5 чанков", embedderAvailable: true))
    }
}

private extension DateFormatter {
    /// Тот же формат, что в ProjectDocsIndexUIStatus (short/short) — свежий
    /// инстанс на каждый тест, чтобы не зависеть от private static форматтера.
    static var docsStatsFormatterForTest: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
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
