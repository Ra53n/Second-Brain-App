// FineTuneRunnerValidateTests.swift — задача 82: FineTuneRunner.validate (P4).
//
// Инжектированный ValidateCLIRunner — реальный Process/validate.py не запускается.
// Проверяет сборку argv (train.jsonl/valid.jsonl, опциональные --system/--min-assistant),
// раздельные stdout/stderr в CLIResult (нужны FineTuneValidationParser'у, который иначе не
// отличит заметки от ошибок) и проброс кода возврата наверх без интерпретации.

import XCTest
@testable import SecondBrain

final class FineTuneRunnerValidateTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-FineTuneRunnerValidate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDataset(systemPromptPath: String? = nil) -> FineTuneDataset {
        FineTuneDataset(id: ".", title: "finetune", workdir: ".", rootURL: tempDir,
                        dataURL: tempDir.appendingPathComponent("data"),
                        trainCount: 10, validCount: 2, split: nil, systemPromptPath: systemPromptPath)
    }

    func testArgumentsContainBothJSONLPathsWithoutOptionalFlags() async {
        var captured: [String]?
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { args in
            captured = args
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())

        _ = await runner.validate(dataset: makeDataset(), minAssistant: nil, maxReuse: nil, systemPromptPath: nil)

        XCTAssertEqual(captured, [
            tempDir.appendingPathComponent("data/train.jsonl").path,
            tempDir.appendingPathComponent("data/valid.jsonl").path
        ], "без system/min-assistant — только пути к train/valid")
    }

    func testSystemFlagAddedOnlyWhenPathProvided() async {
        var captured: [String]?
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { args in
            captured = args
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())

        _ = await runner.validate(dataset: makeDataset(), minAssistant: nil, maxReuse: nil,
                                  systemPromptPath: "/x/system_prompt.txt")

        XCTAssertEqual(captured?.suffix(2), ["--system", "/x/system_prompt.txt"])
    }

    func testSystemFlagAbsentWhenPathIsNil() async {
        var captured: [String]?
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { args in
            captured = args
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())

        _ = await runner.validate(dataset: makeDataset(), minAssistant: nil, maxReuse: nil, systemPromptPath: nil)

        XCTAssertFalse(captured?.contains("--system") ?? true)
    }

    func testMinAssistantFlagAddedOnlyWhenValueProvided() async {
        var captured: [String]?
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { args in
            captured = args
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())

        _ = await runner.validate(dataset: makeDataset(), minAssistant: 30, maxReuse: nil, systemPromptPath: nil)

        XCTAssertEqual(captured?.suffix(2), ["--min-assistant", "30"])
    }

    /// Задача 84: без своего порога повторов датасет классификации валиден быть не может —
    /// сотни примеров с одной меткой `validate.py` считает дублями.
    func testMaxReuseFlagAddedOnlyWhenValueProvided() async {
        var captured: [String]?
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { args in
            captured = args
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())

        _ = await runner.validate(dataset: makeDataset(), minAssistant: nil, maxReuse: 900,
                                  systemPromptPath: nil)

        XCTAssertEqual(captured?.suffix(2), ["--max-reuse", "900"])
    }

    func testMaxReuseFlagAbsentWhenValueIsNil() async {
        var captured: [String]?
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { args in
            captured = args
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())

        _ = await runner.validate(dataset: makeDataset(), minAssistant: 30, maxReuse: nil,
                                  systemPromptPath: nil)

        XCTAssertFalse(captured?.contains("--max-reuse") ?? true)
    }

    func testMinAssistantFlagAbsentWhenValueIsNil() async {
        var captured: [String]?
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { args in
            captured = args
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())

        _ = await runner.validate(dataset: makeDataset(), minAssistant: nil, maxReuse: nil, systemPromptPath: nil)

        XCTAssertFalse(captured?.contains("--min-assistant") ?? true)
    }

    func testBothOptionalFlagsPresentInOrderWhenBothProvided() async {
        var captured: [String]?
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { args in
            captured = args
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())

        _ = await runner.validate(dataset: makeDataset(), minAssistant: 120, maxReuse: nil,
                                  systemPromptPath: "/x/system_prompt.txt")

        XCTAssertEqual(captured, [
            tempDir.appendingPathComponent("data/train.jsonl").path,
            tempDir.appendingPathComponent("data/valid.jsonl").path,
            "--system", "/x/system_prompt.txt",
            "--min-assistant", "120"
        ])
    }

    /// stdout/stderr обязаны доехать раздельно — иначе FineTuneValidationParser не
    /// отличит заметки (stdout) от ошибок (stderr).
    func testStdoutAndStderrArePassedThroughSeparately() async {
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { _ in
            .init(status: 1, output: "", stdout: "заметка\n", stderr: "ОШИБКИ (1):\n  a.jsonl:1: текст")
        }, registry: BackgroundProcessRegistry())

        let result = await runner.validate(dataset: makeDataset(), minAssistant: nil, maxReuse: nil, systemPromptPath: nil)

        XCTAssertEqual(result.stdout, "заметка\n")
        XCTAssertEqual(result.stderr, "ОШИБКИ (1):\n  a.jsonl:1: текст")
    }

    func testNonZeroStatusReachesCaller() async {
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { _ in
            .init(status: 1, output: "boom")
        }, registry: BackgroundProcessRegistry())

        let result = await runner.validate(dataset: makeDataset(), minAssistant: nil, maxReuse: nil, systemPromptPath: nil)

        XCTAssertEqual(result.status, 1)
    }

    /// Каталог finetune/ не найден — validate() не зовёт инжектированный CLI вовсе,
    /// отдаёт status < 0 сразу (это ошибка уровня приложения, не результат проверки).
    func testMissingFineTuneRootShortCircuitsWithoutCallingCLI() async {
        var cliCalled = false
        let runner = FineTuneRunner(fineTuneRoot: nil, validateCLI: { _ in
            cliCalled = true
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())

        let result = await runner.validate(dataset: makeDataset(), minAssistant: nil, maxReuse: nil, systemPromptPath: nil)

        XCTAssertEqual(result.status, -1)
        XCTAssertFalse(cliCalled, "без корня finetune/ CLI вообще не вызывается")
    }
}
