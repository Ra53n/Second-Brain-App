// FineTuneDatasetScannerTests.swift — задача 81: сканирование каталогов-датасетов (I/O).
//
// Признак датасета — <dir>/data/train.jsonl; корень и подкаталоги глубины 1;
// split.json может отсутствовать (реальный кейс dictation); sidecar короче основного
// файла — без краша; отсутствующий finetune/ — пустой список, не ошибка. Задача 82
// дополняет: baselineURL/criteriaURL, включая nil-ветки (нет каталога/файла). Задача 83:
// tunedURL — тот же принцип, плюс отдельный nil-кейс на пустой каталог tuned/.

import XCTest
@testable import SecondBrain

final class FineTuneDatasetScannerTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-FineTuneScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func jsonl(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    private func exampleLine(_ tag: String) -> String {
        #"{"messages":[{"role":"system","content":"S"},{"role":"user","content":"U\#(tag)"},{"role":"assistant","content":"A\#(tag)"}]}"#
    }

    // MARK: - scan()

    func testRootDatasetFoundWhenDataTrainExists() throws {
        try write(jsonl([exampleLine("1"), exampleLine("2")]),
                  to: tempDir.appendingPathComponent("data/train.jsonl"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertEqual(datasets.count, 1)
        XCTAssertEqual(datasets[0].workdir, ".")
        XCTAssertEqual(datasets[0].trainCount, 2)
        XCTAssertEqual(datasets[0].validCount, 0, "valid.jsonl отсутствует")
    }

    func testRootNotFoundWithoutDataTrain() throws {
        // Каталог существует, но data/train.jsonl нет.
        XCTAssertEqual(FineTuneDatasetScanner.scan(fineTuneRoot: tempDir), [])
    }

    func testSubdirectoryDepthOneFound() throws {
        try write(jsonl([exampleLine("1")]),
                  to: tempDir.appendingPathComponent("dictation/data/train.jsonl"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertEqual(datasets.count, 1)
        XCTAssertEqual(datasets[0].workdir, "dictation")
        XCTAssertEqual(datasets[0].title, "dictation")
        XCTAssertEqual(datasets[0].trainCount, 1)
    }

    func testDepthTwoSubdirectoryIsNotFound() throws {
        // finetune/outer/inner/data/train.jsonl — outer сам по себе не датасет.
        try write(jsonl([exampleLine("1")]),
                  to: tempDir.appendingPathComponent("outer/inner/data/train.jsonl"))
        XCTAssertEqual(FineTuneDatasetScanner.scan(fineTuneRoot: tempDir), [],
                       "сканирование не рекурсивное глубже одного уровня")
    }

    func testRootAndSubdirectoryBothFound() throws {
        try write(jsonl([exampleLine("1")]), to: tempDir.appendingPathComponent("data/train.jsonl"))
        try write(jsonl([exampleLine("1"), exampleLine("2"), exampleLine("3")]),
                  to: tempDir.appendingPathComponent("dictation/data/train.jsonl"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertEqual(datasets.map(\.workdir).sorted(), [".", "dictation"])
    }

    /// split.json может отсутствовать — реальный кейс dictation, не ошибка.
    func testMissingSplitJSONIsNotAnError() throws {
        try write(jsonl([exampleLine("1")]),
                  to: tempDir.appendingPathComponent("dictation/data/train.jsonl"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertNil(datasets.first?.split)
    }

    func testSplitJSONParsedWhenPresent() throws {
        try write(jsonl([exampleLine("1")]), to: tempDir.appendingPathComponent("data/train.jsonl"))
        let split = #"{"seed":7,"eval_fraction_target":0.1,"eval_posts":["a","b"],"counts":{"train":1,"valid":0}}"#
        try write(split, to: tempDir.appendingPathComponent("data/split.json"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertEqual(datasets.first?.split?.seed, 7)
        XCTAssertEqual(datasets.first?.split?.evalPosts, ["a", "b"])
        XCTAssertEqual(datasets.first?.split?.counts.train, 1)
    }

    func testMissingFineTuneRootYieldsEmptyList() {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        XCTAssertEqual(FineTuneDatasetScanner.scan(fineTuneRoot: missing), [])
    }

    // MARK: - baselineURL / criteriaURL (задача 82) — «отсутствие даёт понятную подсказку»

    func testBaselineURLSetWhenDirectoryExists() throws {
        try write(jsonl([exampleLine("1")]), to: tempDir.appendingPathComponent("data/train.jsonl"))
        let baselineDir = tempDir.appendingPathComponent("baseline")
        try FileManager.default.createDirectory(at: baselineDir, withIntermediateDirectories: true)
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertEqual(datasets.first?.baselineURL?.path, baselineDir.path)
    }

    func testBaselineURLNilWhenDirectoryMissing() throws {
        try write(jsonl([exampleLine("1")]), to: tempDir.appendingPathComponent("data/train.jsonl"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertNil(datasets.first?.baselineURL, "нет baseline/ — понятная подсказка, не ошибка")
    }

    func testBaselineURLNilWhenPathIsAFileNotDirectory() throws {
        try write(jsonl([exampleLine("1")]), to: tempDir.appendingPathComponent("data/train.jsonl"))
        try write("не каталог", to: tempDir.appendingPathComponent("baseline"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertNil(datasets.first?.baselineURL, "baseline — файл, не каталог")
    }

    func testCriteriaURLSetWhenFileExists() throws {
        try write(jsonl([exampleLine("1")]), to: tempDir.appendingPathComponent("data/train.jsonl"))
        try write("# Критерии", to: tempDir.appendingPathComponent("criteria.md"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertEqual(datasets.first?.criteriaURL?.path, tempDir.appendingPathComponent("criteria.md").path)
    }

    func testCriteriaURLNilWhenFileMissing() throws {
        try write(jsonl([exampleLine("1")]), to: tempDir.appendingPathComponent("data/train.jsonl"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertNil(datasets.first?.criteriaURL, "нет criteria.md — понятная подсказка, не ошибка")
    }

    // MARK: - tunedURL (задача 83) — как baselineURL, но нужен хотя бы один файл внутри

    func testTunedURLSetWhenDirectoryHasFile() throws {
        try write(jsonl([exampleLine("1")]), to: tempDir.appendingPathComponent("data/train.jsonl"))
        try write("# ответ", to: tempDir.appendingPathComponent("tuned/answer-1.md"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertEqual(datasets.first?.tunedURL?.path, tempDir.appendingPathComponent("tuned").path)
    }

    func testTunedURLNilWhenDirectoryMissing() throws {
        try write(jsonl([exampleLine("1")]), to: tempDir.appendingPathComponent("data/train.jsonl"))
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertNil(datasets.first?.tunedURL, "нет tuned/ — понятная подсказка, не ошибка")
    }

    func testTunedURLNilWhenDirectoryEmpty() throws {
        try write(jsonl([exampleLine("1")]), to: tempDir.appendingPathComponent("data/train.jsonl"))
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("tuned"),
                                                withIntermediateDirectories: true)
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: tempDir)
        XCTAssertNil(datasets.first?.tunedURL, "пустой tuned/ — снимок ещё не снят")
    }

    // MARK: - lineCount()

    func testLineCountCountsNonEmptyLinesOnly() throws {
        let url = tempDir.appendingPathComponent("data/valid.jsonl")
        try write("a\n\nb\n   \nc", to: url)
        // "   " не омиттед split(separator:"\n", omittingEmptySubsequences: true) —
        // не пустая строка (пробелы), считается отдельной строкой.
        XCTAssertEqual(FineTuneDatasetScanner.lineCount(of: url), 4)
    }

    func testLineCountOfEmptyFileIsZero() throws {
        let url = tempDir.appendingPathComponent("data/empty.jsonl")
        try write("", to: url)
        XCTAssertEqual(FineTuneDatasetScanner.lineCount(of: url), 0)
    }

    func testLineCountOfMissingFileIsZero() {
        XCTAssertEqual(FineTuneDatasetScanner.lineCount(of: tempDir.appendingPathComponent("missing.jsonl")), 0)
    }

    // MARK: - examples()

    func testExamplesWithoutSidecarHaveNilMeta() throws {
        let dataURL = tempDir.appendingPathComponent("data/train.jsonl")
        try write(jsonl([exampleLine("1"), exampleLine("2")]), to: dataURL)
        let examples = FineTuneDatasetScanner.examples(dataURL: dataURL, metaURL: nil)
        XCTAssertEqual(examples.count, 2)
        XCTAssertNil(examples[0].meta)
        XCTAssertNil(examples[1].meta)
    }

    /// Sidecar короче основного файла — примеры за пределами меты получают nil, без краша.
    func testSidecarShorterThanDataYieldsExamplesWithoutMetaForExtras() throws {
        let dataURL = tempDir.appendingPathComponent("data/train.jsonl")
        let metaURL = tempDir.appendingPathComponent("data/train.meta.jsonl")
        try write(jsonl([exampleLine("1"), exampleLine("2"), exampleLine("3")]), to: dataURL)
        try write(jsonl([#"{"id":"only-one","source_post":"p","task_type":"t"}"#]), to: metaURL)

        let examples = FineTuneDatasetScanner.examples(dataURL: dataURL, metaURL: metaURL)
        XCTAssertEqual(examples.count, 3, "недостаток sidecar-строк не режет примеры")
        XCTAssertEqual(examples[0].meta?.id, "only-one")
        XCTAssertNil(examples[1].meta, "нет соответствующей sidecar-строки")
        XCTAssertNil(examples[2].meta)
    }

    /// Битая строка данных пропускается целиком (не всплывает как «пример без меты»).
    func testInvalidDataLineIsSkipped() throws {
        let dataURL = tempDir.appendingPathComponent("data/train.jsonl")
        try write(jsonl([exampleLine("1"), "{ битый json", exampleLine("2")]), to: dataURL)
        let examples = FineTuneDatasetScanner.examples(dataURL: dataURL, metaURL: nil)
        XCTAssertEqual(examples.count, 2)
    }

    func testExamplesOfMissingFileIsEmpty() {
        let missing = tempDir.appendingPathComponent("data/train.jsonl")
        XCTAssertEqual(FineTuneDatasetScanner.examples(dataURL: missing, metaURL: nil), [])
    }
}
