// RunCommandToolTests.swift — тесты run_command (задача 39).
//
// Реальный /bin/zsh на временной папке: код возврата, объединённый вывод,
// cwd = корень, кап вывода, таймаут гасит процесс. Реестр процессов —
// изолированный экземпляр (не shared), чтобы тесты не трогали процессы
// приложения.

import XCTest
@testable import SecondBrain

final class RunCommandToolTests: XCTestCase {

    private var root: URL!
    private var registry: BackgroundProcessRegistry!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runcommand-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        registry = BackgroundProcessRegistry()
    }

    override func tearDownWithError() throws {
        registry.terminateAll(gracePeriod: 0.5)
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func run(_ argumentsJSON: String) async -> ToolResult {
        let tool = RunCommandTool(registry: registry)
        let arguments = JSONValue.parse(argumentsJSON) ?? .object([:])
        return await tool.execute(ToolContext(repoRoot: root, arguments: arguments))
    }

    func testEchoAndExitCode() async {
        let result = await run(#"{"command":"echo привет"}"#)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("привет"), result.text)
        XCTAssertTrue(result.text.contains("[exit code: 0]"), result.text)
    }

    func testNonZeroExitCodeIsNotToolError() async {
        // Упавшая команда — не сбой инструмента: модель видит вывод и код.
        let result = await run(#"{"command":"echo провал; exit 3"}"#)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("провал"), result.text)
        XCTAssertTrue(result.text.contains("[exit code: 3]"), result.text)
    }

    func testStderrIsCaptured() async {
        let result = await run(#"{"command":"echo беда 1>&2"}"#)
        XCTAssertTrue(result.text.contains("беда"), result.text)
    }

    func testRunsInProjectRoot() async throws {
        try "маркер".write(to: root.appendingPathComponent("here.txt"),
                           atomically: true, encoding: .utf8)
        let result = await run(#"{"command":"ls"}"#)
        XCTAssertTrue(result.text.contains("here.txt"), result.text)
    }

    func testOutputIsCapped() async {
        // ~100 КБ вывода → обрезка до капа с пометкой.
        let result = await run(#"{"command":"yes строка | head -c 100000"}"#)
        XCTAssertTrue(result.text.contains("вывод обрезан"), result.text)
        XCTAssertLessThan(result.text.count, RunCommandTool.maxOutputChars + 200)
    }

    func testTimeoutKillsProcess() async {
        let start = Date()
        let result = await run(#"{"command":"sleep 30","timeoutSeconds":1}"#)
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("не завершилась"), result.text)
        // 1 с таймаут + 2 с грейс + запас — но точно не 30 с.
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    func testMissingCommandArgument() async {
        let result = await run("{}")
        XCTAssertTrue(result.isError, result.text)
    }
}
