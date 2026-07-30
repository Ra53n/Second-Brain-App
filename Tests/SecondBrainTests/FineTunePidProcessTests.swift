// FineTunePidProcessTests.swift — задача 81: ManagedProcess поверх голого pid.
//
// pid ≤ 1 отвергается (killpg(0,…) бьёт по группе приложения, killpg(1,…) — по
// launchd); detachFromQuit() переводит оба сигнала в no-op. НИКОГДА не шлём
// реальный SIGTERM/SIGKILL на getpid() — только после detachFromQuit(), когда
// сигналы гарантированно no-op.

import XCTest
@testable import SecondBrain

final class FineTunePidProcessTests: XCTestCase {

    func testZeroPidIsRejected() {
        XCTAssertNil(FineTunePidProcess(pid: 0), "killpg(0,…) бьёт по группе процессов приложения")
    }

    func testOnePidIsRejected() {
        XCTAssertNil(FineTunePidProcess(pid: 1), "killpg(1,…) бьёт по launchd")
    }

    func testNegativePidIsRejected() {
        XCTAssertNil(FineTunePidProcess(pid: -42))
    }

    func testOwnPidIsAcceptedAndRunning() {
        let process = FineTunePidProcess(pid: getpid())
        XCTAssertNotNil(process)
        XCTAssertEqual(process?.isRunning, true)
        XCTAssertEqual(process?.isDetached, false)
    }

    /// После detachFromQuit(): isRunning == false, оба сигнала — no-op. Единственно
    /// безопасный способ проверить это на getpid() — сигналы шлются ПОСЛЕ детача,
    /// когда guard !isDetached уже гарантирует ранний return.
    func testDetachFromQuitMakesSignalsNoOpAndProcessSurvives() {
        guard let process = FineTunePidProcess(pid: getpid()) else {
            return XCTFail("getpid() обязан быть валидным pid")
        }
        process.detachFromQuit()
        XCTAssertTrue(process.isDetached)
        XCTAssertFalse(process.isRunning, "отвязанный прогон больше не считается нашим")

        process.sendTerminationSignal()
        process.sendKillSignal()

        // Процесс теста дожил до этой строки — оба сигнала были no-op.
        XCTAssertEqual(kill(getpid(), 0), 0, "тестовый процесс должен остаться жив")
    }
}
