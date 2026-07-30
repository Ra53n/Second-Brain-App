// FineTuneEnvironmentTests.swift — задача 81 (доработка, В8): таймаут пробы python.
//
// Реальный Process — но это тонкие shell-скрипты (обычный exit / долгий sleep), не
// сеть и не mlx-lm: тот же приём, что и в RunCommandToolTests.testTimeoutKillsProcess.

import XCTest
@testable import SecondBrain

final class FineTuneEnvironmentTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-FineTuneEnv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func script(_ body: String, name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testProbeReturnsTrueForZeroExitCode() throws {
        let ok = FineTuneEnvironment.probe(try script("#!/bin/sh\nexit 0\n", name: "ok-python"))
        XCTAssertTrue(ok)
    }

    func testProbeReturnsFalseForNonZeroExitCode() throws {
        let ok = FineTuneEnvironment.probe(try script("#!/bin/sh\nexit 1\n", name: "bad-python"))
        XCTAssertFalse(ok)
    }

    /// Зависший интерпретатор не должен блокировать пробу (и, транзитивно, старт/выход
    /// приложения) навсегда — SIGTERM, затем SIGKILL выжившему.
    func testProbeTimesOutAndKillsHangingProcess() throws {
        let script = try script("#!/bin/sh\nsleep 30\n", name: "slow-python")
        let start = Date()
        let ok = FineTuneEnvironment.probe(script, timeoutSeconds: 1)
        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "таймаут (1 с) + грейс, не полные 30 с")
    }

    func testProbeReturnsFalseForNonExecutablePath() {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        XCTAssertFalse(FineTuneEnvironment.probe(missing))
    }
}
