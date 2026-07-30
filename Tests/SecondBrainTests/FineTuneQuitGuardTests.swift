// FineTuneQuitGuardTests.swift — задача 81 (доработка, Б1): диалог выхода не должен
// гасить чужой прогон (isAdoptedExternally) — инвариант №2. Регрессия: AppModel.wire()
// раньше брал любой .running прогон в пробу, не глядя на isAdoptedExternally.

import XCTest
@testable import SecondBrain

final class FineTuneQuitGuardTests: XCTestCase {
    private func makeRun(status: FineTuneRun.Status, isAdoptedExternally: Bool) -> FineTuneRun {
        var run = FineTuneRun(workdir: ".", datasetTitle: "d", model: "m",
                              hyperparameters: FineTuneHyperparameters(), logPath: "log", adapterPath: "a")
        run.status = status
        run.isAdoptedExternally = isAdoptedExternally
        return run
    }

    func testActiveRunSkipsForeignRun() {
        let foreign = makeRun(status: .running, isAdoptedExternally: true)
        XCTAssertNil(FineTuneQuitGuard.activeRun(in: [foreign]),
                     "чужой прогон не должен показываться в диалоге выхода — его нельзя гасить")
    }

    func testActiveRunReturnsOwnRunningRun() {
        let own = makeRun(status: .running, isAdoptedExternally: false)
        XCTAssertEqual(FineTuneQuitGuard.activeRun(in: [own])?.id, own.id)
    }

    func testActiveRunIgnoresFinishedRuns() {
        let finished = makeRun(status: .finished, isAdoptedExternally: false)
        XCTAssertNil(FineTuneQuitGuard.activeRun(in: [finished]))
    }

    func testActiveRunPrefersOwnOverForeignWhenBothPresent() {
        let foreign = makeRun(status: .running, isAdoptedExternally: true)
        let own = makeRun(status: .running, isAdoptedExternally: false)
        XCTAssertEqual(FineTuneQuitGuard.activeRun(in: [foreign, own])?.id, own.id)
    }

    func testActiveRunOnEmptyRunsIsNil() {
        XCTAssertNil(FineTuneQuitGuard.activeRun(in: []))
    }

    /// waitFor не должен вешать вызывающий поток дольше timeout, даже если операция
    /// сама по себе дольше: applicationShouldTerminate не может зависать на Cmd+Q.
    func testWaitForReturnsAfterTimeoutEvenIfOperationIsSlower() {
        let start = Date()
        let operationDone = expectation(description: "операция всё же доработала в фоне")
        FineTuneQuitGuard.waitFor(timeout: 0.2) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            operationDone.fulfill()
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6, "waitFor не должен ждать дольше таймаута")
        wait(for: [operationDone], timeout: 2)
    }
}
