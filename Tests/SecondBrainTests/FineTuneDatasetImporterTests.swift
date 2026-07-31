// FineTuneDatasetImporterTests.swift — задача 83: импорт внешнего JSONL в
// finetune/<name> (I/O, temp-директории).
//
// Успешный импорт пишет полный набор файлов, train+valid дословно совпадают с
// исходником, meta-строки соответствуют, сканер видит новый датасет; дубль имени
// не трогает существующий каталог; < 2 примеров не создаёт каталог вовсе.
//
// Ревью задачи 83: недопустимое имя (`badName`) не создаёт ничего; ошибка createDirectory
// не-«уже существует» (несуществующий root) → `writeFailed`, не `datasetExists`; сбой
// записи ПОСЛЕ создания root/<name> (инжектированный FileManager) откатывает каталог.

import XCTest
@testable import SecondBrain

final class FineTuneDatasetImporterTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-FineTuneImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func line(system: String = "Ты — ассистент.", user: String, assistant: String) -> String {
        let payload = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
                ["role": "assistant", "content": assistant]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func sourceText(count: Int) -> String {
        (0..<count).map { line(user: "U\($0)", assistant: "A\($0)") }.joined(separator: "\n")
    }

    private func linesOf(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func testSuccessfulImportWritesFullFileSet() throws {
        let source = sourceText(count: 10)
        let id = try FineTuneDatasetImporter.importDataset(from: source, name: "mydataset", into: root, seed: 42)
        XCTAssertEqual(id, "mydataset")

        let dataURL = root.appendingPathComponent("mydataset/data")
        let expectedFiles = ["raw.jsonl", "train.jsonl", "valid.jsonl",
                             "raw.meta.jsonl", "train.meta.jsonl", "valid.meta.jsonl", "split.json"]
        for name in expectedFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dataURL.appendingPathComponent(name).path),
                          "\(name) не создан")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("mydataset/system_prompt.txt").path))
    }

    func testTrainAndValidLinesAreVerbatimFromSource() throws {
        let sourceLines = (0..<10).map { line(user: "U\($0)", assistant: "A\($0)") }
        let id = try FineTuneDatasetImporter.importDataset(
            from: sourceLines.joined(separator: "\n"), name: "verbatim", into: root, seed: 7)
        let dataURL = root.appendingPathComponent("\(id)/data")

        let train = try linesOf(dataURL.appendingPathComponent("train.jsonl"))
        let valid = try linesOf(dataURL.appendingPathComponent("valid.jsonl"))
        XCTAssertEqual(train.count + valid.count, 10)
        for rawLine in train + valid {
            XCTAssertTrue(sourceLines.contains(rawLine), "строка отличается от исходной дословно")
        }
        XCTAssertEqual(Set(train + valid).count, 10, "не должно быть дублей/потерь между train и valid")
    }

    func testMetaLinesCorrespondToSplitPositions() throws {
        let id = try FineTuneDatasetImporter.importDataset(
            from: sourceText(count: 10), name: "withmeta", into: root, seed: 7)
        let dataURL = root.appendingPathComponent("\(id)/data")

        let trainCount = try linesOf(dataURL.appendingPathComponent("train.jsonl")).count
        let trainMetaCount = try linesOf(dataURL.appendingPathComponent("train.meta.jsonl")).count
        let validCount = try linesOf(dataURL.appendingPathComponent("valid.jsonl")).count
        let validMetaCount = try linesOf(dataURL.appendingPathComponent("valid.meta.jsonl")).count
        XCTAssertEqual(trainCount, trainMetaCount)
        XCTAssertEqual(validCount, validMetaCount)

        let rawMeta = try linesOf(dataURL.appendingPathComponent("raw.meta.jsonl"))
        XCTAssertEqual(rawMeta.count, 10)
        for metaLine in rawMeta {
            XCTAssertNotNil(FineTuneJSONL.parseMeta(line: metaLine))
        }
    }

    func testScannerSeesNewDatasetWithCorrectCounts() throws {
        let id = try FineTuneDatasetImporter.importDataset(
            from: sourceText(count: 10), name: "scanned", into: root, seed: 7)
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: root)
        let dataset = datasets.first { $0.id == id }
        XCTAssertNotNil(dataset)
        XCTAssertEqual((dataset?.trainCount ?? 0) + (dataset?.validCount ?? 0), 10)
        XCTAssertNotNil(dataset?.systemPromptPath)
        XCTAssertNotNil(dataset?.split)
    }

    func testDuplicateNameThrowsAndLeavesExistingDatasetUntouched() throws {
        _ = try FineTuneDatasetImporter.importDataset(from: sourceText(count: 5), name: "dup", into: root, seed: 1)
        let markerURL = root.appendingPathComponent("dup/data/train.jsonl")
        let before = try Data(contentsOf: markerURL)

        XCTAssertThrowsError(
            try FineTuneDatasetImporter.importDataset(from: sourceText(count: 5), name: "dup", into: root, seed: 2)
        ) { error in
            XCTAssertEqual(error as? FineTuneImportError, .datasetExists("dup"))
        }
        let after = try Data(contentsOf: markerURL)
        XCTAssertEqual(before, after, "существующий датасет не должен измениться")
    }

    func testTooFewExamplesThrowsAndCreatesNoDirectory() throws {
        XCTAssertThrowsError(
            try FineTuneDatasetImporter.importDataset(from: sourceText(count: 1), name: "toofew", into: root, seed: 1)
        ) { error in
            XCTAssertEqual(error as? FineTuneImportError, .tooFewExamples(validCount: 1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("toofew").path))
    }

    func testZeroValidExamplesThrowsTooFewExamples() throws {
        XCTAssertThrowsError(
            try FineTuneDatasetImporter.importDataset(from: "{ не json", name: "empty", into: root, seed: 1)
        ) { error in
            XCTAssertEqual(error as? FineTuneImportError, .tooFewExamples(validCount: 0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("empty").path))
    }

    /// Мид-запись ошибку (сбой ПОСЛЕ создания root/<name>, при записи data/) моделирует
    /// FileManager-сабкласс — откат отрабатывает тем же кодом, что и datasetExists.
    func testWriteFailureAfterDirectoryCreationRollsBackAndPropagatesError() throws {
        let thrower = ThrowingOnDataDirectoryFileManager()
        XCTAssertThrowsError(
            try FineTuneDatasetImporter.importDataset(
                from: sourceText(count: 5), name: "rollback", into: root, seed: 1, fileManager: thrower)
        ) { error in
            XCTAssertEqual((error as NSError).localizedDescription, "boom", "ошибка write() проброшена как есть")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rollback").path),
                       "ошибка внутри write() должна откатить root/<name> целиком")
    }

    // MARK: - валидация имени (задача 83, ревью)

    func testBadNameRejectedWithoutCreatingAnyDirectory() throws {
        for name in ["../evil", "data", ""] {
            XCTAssertThrowsError(
                try FineTuneDatasetImporter.importDataset(from: sourceText(count: 5), name: name, into: root, seed: 1)
            ) { error in
                XCTAssertEqual(error as? FineTuneImportError, .badName(name), name)
            }
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(entries.isEmpty, "недопустимое имя не должно создавать каталогов")
    }

    // MARK: - ошибка createDirectory ≠ datasetExists (задача 83, ревью)

    func testNonExistentRootThrowsWriteFailedNotDatasetExists() throws {
        let missingRoot = root.appendingPathComponent("nested/missing")
        XCTAssertThrowsError(
            try FineTuneDatasetImporter.importDataset(from: sourceText(count: 5), name: "x", into: missingRoot, seed: 1)
        ) { error in
            guard case .writeFailed = error as? FineTuneImportError else {
                return XCTFail("ожидался .writeFailed, получено \(error)")
            }
        }
    }

    func testReadSourceRejectsFileLargerThanLimit() throws {
        let fileURL = root.appendingPathComponent("big.jsonl")
        try Data(repeating: 0x41, count: 20).write(to: fileURL)
        XCTAssertThrowsError(try FineTuneDatasetImporter.readSource(url: fileURL, maxBytes: 10)) { error in
            XCTAssertEqual(error as? FineTuneImportError, .fileTooLarge)
        }
    }

    func testReadSourceReturnsTextWithinLimit() throws {
        let fileURL = root.appendingPathComponent("small.jsonl")
        try Data("hello".utf8).write(to: fileURL)
        let text = try FineTuneDatasetImporter.readSource(url: fileURL, maxBytes: 50_000_000)
        XCTAssertEqual(text, "hello")
    }
}

/// Пропускает создание root/<name>, бросает на data/ — моделирует сбой записи
/// ПОСЛЕ создания каталога датасета, без реального заполнения диска.
private final class ThrowingOnDataDirectoryFileManager: FileManager {
    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.lastPathComponent == "data" {
            throw NSError(domain: "FineTuneDatasetImporterTests", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        try super.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories,
                                  attributes: attributes)
    }
}
