// KnowledgeBaseTests.swift — тесты задачи 34 (реестр баз знаний).
//
// Покрытие по критериям приёмки:
//  - KnowledgeBaseStore: нормализация (встроенные vault/project всегда на
//    месте), persist/load round-trip, карантин битого файла, добавление/
//    удаление папочных баз, защита встроенных от удаления/переименования;
//  - FolderDocsLoader: рекурсивный сбор .md, скип dot-папок, лимиты;
//  - FolderIndexService: ленивая синхронизация, поиск, смена тега эмбеддера.

import XCTest
@testable import SecondBrain

// MARK: - KnowledgeBaseStore

@MainActor
final class KnowledgeBaseStoreTests: XCTestCase {

    private var tempDir: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kb-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("knowledge-bases.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testFreshStoreHasBuiltins() {
        let store = KnowledgeBaseStore(fileURL: fileURL)
        XCTAssertEqual(store.bases.map(\.id),
                       [KnowledgeBase.vaultID, KnowledgeBase.projectID],
                       "пустой реестр нормализуется до двух встроенных баз")
        XCTAssertTrue(store.bases.allSatisfy(\.enabled))
    }

    func testAddFolderPersistsAndReloads() {
        let store = KnowledgeBaseStore(fileURL: fileURL)
        let folder = tempDir.appendingPathComponent("Notes", isDirectory: true)
        let added = store.addFolder(url: folder)
        XCTAssertEqual(added.kind, .folder)
        XCTAssertEqual(added.name, "Notes")

        // Повторное добавление того же пути не создаёт дубликат.
        let again = store.addFolder(url: folder)
        XCTAssertEqual(again.id, added.id)
        XCTAssertEqual(store.bases.count, 3)

        // Перезагрузка из файла сохраняет запись и порядок (встроенные первыми).
        let reloaded = KnowledgeBaseStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.bases.map(\.id),
                       [KnowledgeBase.vaultID, KnowledgeBase.projectID, added.id])
        XCTAssertEqual(reloaded.base(id: added.id)?.path, folder.standardizedFileURL.path)
    }

    func testBuiltinsCannotBeRemovedOrRenamed() {
        let store = KnowledgeBaseStore(fileURL: fileURL)
        store.removeBase(id: KnowledgeBase.vaultID)
        store.rename(id: KnowledgeBase.projectID, to: "Другое")
        XCTAssertEqual(store.bases.count, 2)
        XCTAssertEqual(store.base(id: KnowledgeBase.projectID)?.name, "Проект")
    }

    func testDisabledBuiltinSurvivesReload() {
        let store = KnowledgeBaseStore(fileURL: fileURL)
        store.setEnabled(id: KnowledgeBase.projectID, false)
        let reloaded = KnowledgeBaseStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.base(id: KnowledgeBase.projectID)?.enabled, false)
        XCTAssertEqual(reloaded.enabledBases.map(\.id), [KnowledgeBase.vaultID])
    }

    func testRemoveFolderBase() {
        let store = KnowledgeBaseStore(fileURL: fileURL)
        let added = store.addFolder(url: tempDir.appendingPathComponent("A"))
        store.removeBase(id: added.id)
        XCTAssertNil(store.base(id: added.id))
        XCTAssertEqual(KnowledgeBaseStore(fileURL: fileURL).bases.count, 2)
    }

    func testRenameFolderBase() {
        let store = KnowledgeBaseStore(fileURL: fileURL)
        let added = store.addFolder(url: tempDir.appendingPathComponent("A"))
        store.rename(id: added.id, to: "  Рабочие заметки  ")
        XCTAssertEqual(store.base(id: added.id)?.name, "Рабочие заметки")
        store.rename(id: added.id, to: "   ")
        XCTAssertEqual(store.base(id: added.id)?.name, "Рабочие заметки",
                       "пустое имя игнорируется")
    }

    func testCorruptFileQuarantined() throws {
        try Data("не json".utf8).write(to: fileURL)
        let store = KnowledgeBaseStore(fileURL: fileURL)
        XCTAssertEqual(store.bases.count, 2, "битый файл → чистый реестр")
        let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "повреждённый файл уходит в карантин, а не удаляется")
    }

    func testNormalizeDropsUnknownAndDuplicatesKeepsEnabled() throws {
        // Запись «из будущего» (незнакомый kind, без пути) и дубликат id
        // отбрасываются; enabled встроенной базы уважается.
        let json = """
        [{"id":"vault","kind":"vault","name":"Vault","enabled":false},
         {"id":"vault","kind":"vault","name":"Vault"},
         {"id":"x1","kind":"web","name":"Сайт"},
         {"id":"x2","kind":"folder","name":"Папка","path":"/tmp/kb-notes"}]
        """
        try Data(json.utf8).write(to: fileURL)
        let store = KnowledgeBaseStore(fileURL: fileURL)
        XCTAssertEqual(store.bases.map(\.id),
                       [KnowledgeBase.vaultID, KnowledgeBase.projectID, "x2"])
        XCTAssertEqual(store.base(id: KnowledgeBase.vaultID)?.enabled, false)
    }
}

// MARK: - FolderDocsLoader

final class FolderDocsLoaderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ content: String = "текст") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testRecursiveMarkdownOnlySorted() throws {
        try write("b.md")
        try write("sub/deep/a.md")
        try write("note.txt")
        try write("image.png")
        let files = FolderDocsLoader.loadFiles(root: root)
        XCTAssertEqual(files.map(\.name), ["b.md", "sub/deep/a.md"],
                       "только .md, рекурсивно, отсортировано по пути")
    }

    func testDotFoldersSkipped() throws {
        try write("note.md")
        try write(".obsidian/config.md")
        try write(".git/readme.md")
        let files = FolderDocsLoader.loadFiles(root: root)
        XCTAssertEqual(files.map(\.name), ["note.md"])
    }

    func testOversizedFileSkipped() throws {
        try write("small.md", "нормальная заметка")
        try write("huge.md", String(repeating: "x", count: FolderDocsLoader.maxFileBytes + 1))
        let files = FolderDocsLoader.loadFiles(root: root)
        XCTAssertEqual(files.map(\.name), ["small.md"],
                       "файл больше лимита — не заметка, а свалка")
    }

    func testMissingFolderGivesEmpty() {
        let missing = root.appendingPathComponent("нет-такой-папки")
        XCTAssertTrue(FolderDocsLoader.loadFiles(root: missing).isEmpty)
    }
}

// MARK: - FolderIndexService

/// Детерминированный мок-эмбеддер со счётчиком вызовов (как в
/// ProjectDocsRagTests): тексты с общими словами ближе друг к другу.
private final class CountingEmbedder: EmbeddingProvider {
    let dimension = 8
    private(set) var embedCallCount = 0

    func embed(_ texts: [String], model: String?) async throws -> [[Float]] {
        embedCallCount += 1
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

final class FolderIndexServiceTests: XCTestCase {

    private var root: URL!
    private var service: FolderIndexService!
    private var embedder: CountingEmbedder!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Рецепты\nБорщ варится два часа со свёклой."
            .write(to: root.appendingPathComponent("рецепты.md"),
                   atomically: true, encoding: .utf8)
        try "# Спорт\nБег по утрам девять километров."
            .write(to: root.appendingPathComponent("спорт.md"),
                   atomically: true, encoding: .utf8)
        service = FolderIndexService()
        embedder = CountingEmbedder()
        try? FileManager.default.removeItem(
            at: FolderIndexService.indexFileURL(root: root).deletingLastPathComponent())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(
            at: FolderIndexService.indexFileURL(root: root).deletingLastPathComponent())
    }

    func testHitsFindRelevantChunk() async {
        let hits = await service.hits(root: root, embedder: embedder, model: nil,
                                      tag: "mock|8",
                                      question: "сколько варится борщ со свёклой",
                                      topK: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.path, "рецепты.md")
    }

    /// Повторный ретрив без изменений файлов не переэмбеддит содержимое
    /// (инкрементальность), смена тега — переэмбеддит (векторы несовместимы).
    func testLazySyncIsIncrementalAndTagChangeRebuilds() async {
        _ = await service.hits(root: root, embedder: embedder, model: nil,
                               tag: "mock|8", question: "вопрос", topK: 1)
        let afterFirst = embedder.embedCallCount

        _ = await service.hits(root: root, embedder: embedder, model: nil,
                               tag: "mock|8", question: "вопрос", topK: 1)
        XCTAssertEqual(embedder.embedCallCount, afterFirst + 1,
                       "без изменений эмбеддится только запрос")

        _ = await service.hits(root: root, embedder: embedder, model: nil,
                               tag: "другая|8", question: "вопрос", topK: 1)
        XCTAssertGreaterThan(embedder.embedCallCount, afterFirst + 2,
                             "смена тега → полная переиндексация")
    }

    func testStatsNilBeforeBuildThenPopulated() async {
        let before = await service.stats(root: root)
        XCTAssertNil(before, "пустую БД не создаём ради статистики")
        _ = await service.hits(root: root, embedder: embedder, model: nil,
                               tag: "mock|8", question: "вопрос", topK: 1)
        let after = await service.stats(root: root)
        XCTAssertEqual(after?.files, 2)
        XCTAssertGreaterThan(after?.chunks ?? 0, 0)
        XCTAssertNotNil(after?.updatedAt)
    }

    func testResetClearsIndex() async {
        _ = await service.hits(root: root, embedder: embedder, model: nil,
                               tag: "mock|8", question: "вопрос", topK: 1)
        await service.reset(root: root)
        let stats = await service.stats(root: root)
        XCTAssertEqual(stats?.chunks ?? 0, 0)
    }
}
