// ConfidenceBatchRunnerTests.swift — батч-прогон confidence pipeline (задача 85): файлы
// пишутся в temp-каталог, summary.md появляется только после ВТОРОГО варианта,
// частичный (отменённый) прогон не пишет ничего.

import XCTest
@testable import SecondBrain

@MainActor
final class ConfidenceBatchRunnerTests: XCTestCase {
    private var tempDir: URL!
    private var dataset: FineTuneDataset!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dataURL = tempDir.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        let lines = try [
            validLine(user: "u1", itemsJSON: #"[{"assignee":null,"task":"сделать A","due":null}]"#),
            validLine(user: "u2", itemsJSON: "[]"),
            validLine(user: "u3", itemsJSON: #"[{"assignee":null,"task":"сделать B","due":null}]"#),
            validLine(user: "u4", itemsJSON: "[]"),
        ]
        try lines.joined(separator: "\n").write(
            to: dataURL.appendingPathComponent("valid.jsonl"), atomically: true, encoding: .utf8)
        dataset = FineTuneDataset(id: "meetings", title: "Встречи", workdir: "meetings", rootURL: tempDir,
                                  dataURL: dataURL, trainCount: 0, validCount: 4, split: nil, systemPromptPath: nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func validLine(user: String, itemsJSON: String) throws -> String {
        let assistant = "{\"action_items\":\(itemsJSON)}"
        let object: [String: Any] = ["messages": [
            ["role": "system", "content": "s"],
            ["role": "user", "content": user],
            ["role": "assistant", "content": assistant],
        ]]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testWritesBaselineArtifactsWithoutSummary() async throws {
        let runner = ConfidenceBatchRunner()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        var progressCalls: [(Int, Int)] = []
        let mdURL = try await runner.run(dataset: dataset, variant: .baseline, provider: provider, system: "system",
                                         onProgress: { progressCalls.append(($0, $1)) })

        XCTAssertTrue(FileManager.default.fileExists(atPath: mdURL.path))
        let jsonURL = tempDir.appendingPathComponent("confidence/baseline.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        let summaryURL = tempDir.appendingPathComponent("confidence/summary.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: summaryURL.path),
                       "summary появляется только после обоих вариантов")
        XCTAssertFalse(progressCalls.isEmpty)

        let rows = try JSONDecoder().decode([BatchRow].self, from: Data(contentsOf: jsonURL))
        XCTAssertEqual(rows.count, 4)
    }

    func testSummaryAppearsAfterSecondVariant() async throws {
        let runner = ConfidenceBatchRunner()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        _ = try await runner.run(dataset: dataset, variant: .baseline, provider: provider, system: "system")
        _ = try await runner.run(dataset: dataset, variant: .tuned, provider: provider, system: "system")

        let summaryURL = tempDir.appendingPathComponent("confidence/summary.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
        let text = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertTrue(text.contains("baseline"))
    }

    func testCancellationWritesNoFiles() async throws {
        let runner = ConfidenceBatchRunner()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        provider.delay = 0.3
        let task = Task {
            try await runner.run(dataset: dataset, variant: .baseline, provider: provider, system: "system")
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("ожидалась отмена")
        } catch is CancellationError {
            // ок
        } catch {
            XCTFail("ожидалась CancellationError, получено \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("confidence").path),
                       "частичный прогон не пишет файлов")
    }

    /// Сетевая ошибка (не отмена) где-то в середине батча — та же гарантия, что и у
    /// отмены: ошибка наружу, ничего частично не записано (P6 — ошибка не глотается).
    func testNetworkErrorDuringBatchPropagatesAndWritesNoFiles() async throws {
        let runner = ConfidenceBatchRunner()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        provider.errorToThrow = LLMError.emptyResponse
        do {
            _ = try await runner.run(dataset: dataset, variant: .baseline, provider: provider, system: "system")
            XCTFail("ожидалась ошибка провайдера")
        } catch {
            XCTAssertEqual(error as? LLMError, .emptyResponse)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("confidence").path),
                       "ошибка сети — ничего не записано, как и при отмене")
    }

    /// Отсутствующий `valid.jsonl` раньше молча давал пустую подборку и «успешный»
    /// отчёт из 0 строк (P6-регрессия ревью задачи 85) — теперь честная ошибка,
    /// артефакты не пишутся вовсе.
    func testMissingValidJSONLThrowsDatasetUnreadableAndWritesNoFiles() async throws {
        let runner = ConfidenceBatchRunner()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let emptyDataURL = emptyRoot.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: emptyDataURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let noFileDataset = FineTuneDataset(id: "meetings", title: "Встречи", workdir: "meetings", rootURL: emptyRoot,
                                            dataURL: emptyDataURL, trainCount: 0, validCount: 0,
                                            split: nil, systemPromptPath: nil)

        do {
            _ = try await runner.run(dataset: noFileDataset, variant: .baseline, provider: provider, system: "system")
            XCTFail("ожидалась ошибка «файл не читается»")
        } catch let error as FineTuneError {
            guard case .datasetUnreadable = error else {
                XCTFail("ожидался .datasetUnreadable, получено \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyRoot.appendingPathComponent("confidence").path),
                       "отсутствующий valid.jsonl не создаёт артефактов")
    }

    /// `valid.jsonl` без единой валидной строки — тоже честная ошибка, не пустой
    /// отчёт: прежний артефакт того же варианта не затирается.
    func testEmptyValidJSONLThrowsValidSetEmptyAndKeepsPreviousArtifact() async throws {
        let runner = ConfidenceBatchRunner()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])

        _ = try await runner.run(dataset: dataset, variant: .baseline, provider: provider, system: "system")
        let jsonURL = tempDir.appendingPathComponent("confidence/baseline.json")
        let previousArtifact = try Data(contentsOf: jsonURL)

        try Data("не json вовсе, ни одной валидной строки\nещё мусор".utf8).write(
            to: dataset.dataURL.appendingPathComponent("valid.jsonl"))

        do {
            _ = try await runner.run(dataset: dataset, variant: .baseline, provider: provider, system: "system")
            XCTFail("ожидалась ошибка «валидных примеров нет»")
        } catch let error as FineTuneError {
            guard case .validSetEmpty = error else {
                XCTFail("ожидался .validSetEmpty, получено \(error)")
                return
            }
        }
        XCTAssertEqual(try Data(contentsOf: jsonURL), previousArtifact,
                       "прежний артефакт не затёрт пустым отчётом из битого valid.jsonl")
    }
}
