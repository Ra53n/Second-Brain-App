// FineTuneRunTickTests.swift — задача 81 (доработка, В5): накопление точек лога,
// кольцевой буфер хвоста, детект смерти pid, выбор .finished/.failed по adapters.
// safetensors, простановка bestIter — извлечено из таймера FineTuneViewModel.tick()
// в чистую функцию именно затем, чтобы это было тестируемо без Timer/actor.

import XCTest
@testable import SecondBrain

final class FineTuneRunTickTests: XCTestCase {
    private func makeRun(pid: Int32? = 123, points: [FineTuneProgressPoint] = [],
                         bestIter: Int? = nil) -> FineTuneRun {
        var run = FineTuneRun(workdir: ".", datasetTitle: "d", model: "m",
                              hyperparameters: FineTuneHyperparameters(), logPath: "log",
                              adapterPath: "adapters")
        run.pid = pid
        run.points = points
        run.bestIter = bestIter
        return run
    }

    private func input(text: String = "", alive: Bool = true, adapterExists: Bool = false,
                       limit: Int = 200) -> FineTuneRunTick.Input {
        FineTuneRunTick.Input(newLogText: text, isProcessAlive: alive, adapterExists: adapterExists,
                              logTailLimit: limit)
    }

    // MARK: - Накопление точек

    func testNewLogTextAppendsPointsWithoutDroppingOld() {
        let existingPoint = FineTuneProgressPoint(iter: 1, kind: .val, loss: 2.0, itPerSec: nil, peakMemGB: nil)
        let run = makeRun(points: [existingPoint])
        let text = "Iter 10: Val loss 1.5\n"

        let outcome = FineTuneRunTick.apply(input(text: text), to: run, existingLogLines: [])

        XCTAssertEqual(outcome.run.points.count, 2, "новые точки добавляются к уже накопленным")
        XCTAssertEqual(outcome.run.points.last?.iter, 10)
    }

    func testEmptyLogTextLeavesPointsAndDisplayLinesUntouched() {
        let run = makeRun(points: [FineTuneProgressPoint(iter: 1, kind: .val, loss: 2.0, itPerSec: nil, peakMemGB: nil)])

        let outcome = FineTuneRunTick.apply(input(text: ""), to: run, existingLogLines: ["старая строка"])

        XCTAssertEqual(outcome.run.points.count, 1)
        XCTAssertEqual(outcome.logLines, ["старая строка"], "без нового текста хвост лога не трогается")
    }

    // MARK: - Кольцевой буфер хвоста лога

    func testDisplayLinesRingBufferTrimsToLimit() {
        let existing = (1...198).map { "строка \($0)" }
        let text = "Iter 1: Val loss 1.0\nIter 2: Val loss 1.0\nIter 3: Val loss 1.0\n"

        let outcome = FineTuneRunTick.apply(input(text: text, limit: 200), to: makeRun(), existingLogLines: existing)

        XCTAssertEqual(outcome.logLines.count, 200, "буфер не растёт бесконечно — обрезан до limit")
        XCTAssertEqual(outcome.logLines.first, "строка 2", "старейшие строки вытесняются новыми")
        XCTAssertEqual(outcome.logLines.last, "Iter 3: Val loss 1.0")
    }

    func testDisplayLinesUnderLimitAreNotTrimmed() {
        let text = "Iter 1: Val loss 1.0\n"

        let outcome = FineTuneRunTick.apply(input(text: text, limit: 200), to: makeRun(), existingLogLines: ["a", "b"])

        XCTAssertEqual(outcome.logLines, ["a", "b", "Iter 1: Val loss 1.0"])
    }

    // MARK: - Детект смерти процесса и выбор .finished/.failed

    func testDeadProcessWithAdapterMarksFinished() {
        let run = makeRun(pid: 123)

        let outcome = FineTuneRunTick.apply(input(alive: false, adapterExists: true), to: run, existingLogLines: [])

        XCTAssertTrue(outcome.finished)
        XCTAssertEqual(outcome.run.status, .finished)
        XCTAssertNotNil(outcome.run.finishedAt)
    }

    func testDeadProcessWithoutAdapterMarksFailed() {
        let run = makeRun(pid: 123)

        let outcome = FineTuneRunTick.apply(input(alive: false, adapterExists: false), to: run, existingLogLines: [])

        XCTAssertTrue(outcome.finished)
        XCTAssertEqual(outcome.run.status, .failed)
    }

    func testAliveProcessIsNotFinishedRegardlessOfAdapter() {
        let run = makeRun(pid: 123)

        let outcome = FineTuneRunTick.apply(input(alive: true, adapterExists: true), to: run, existingLogLines: [])

        XCTAssertFalse(outcome.finished)
        XCTAssertEqual(outcome.run.status, .running)
    }

    func testMissingPidNeverMarksFinishedEvenIfNotAlive() {
        let run = makeRun(pid: nil)

        let outcome = FineTuneRunTick.apply(input(alive: false, adapterExists: true), to: run, existingLogLines: [])

        XCTAssertFalse(outcome.finished, "без pid решать «жив/мёртв» нечего")
        XCTAssertEqual(outcome.run.status, .running)
    }

    // MARK: - bestIter

    func testFinishingSetsBestIterFromPointsWhenNil() {
        let points = [
            FineTuneProgressPoint(iter: 1, kind: .val, loss: 2.0, itPerSec: nil, peakMemGB: nil),
            FineTuneProgressPoint(iter: 50, kind: .val, loss: 1.0, itPerSec: nil, peakMemGB: nil)
        ]
        let run = makeRun(pid: 123, points: points, bestIter: nil)

        let outcome = FineTuneRunTick.apply(input(alive: false, adapterExists: true), to: run, existingLogLines: [])

        XCTAssertEqual(outcome.run.bestIter, 50)
    }

    func testFinishingKeepsAlreadySetBestIter() {
        let points = [FineTuneProgressPoint(iter: 50, kind: .val, loss: 1.0, itPerSec: nil, peakMemGB: nil)]
        let run = makeRun(pid: 123, points: points, bestIter: 1)

        let outcome = FineTuneRunTick.apply(input(alive: false, adapterExists: true), to: run, existingLogLines: [])

        XCTAssertEqual(outcome.run.bestIter, 1, "уже проставленный bestIter не перезаписывается")
    }

    func testFinishingWithoutValPointsLeavesBestIterNil() {
        let run = makeRun(pid: 123, points: [], bestIter: nil)

        let outcome = FineTuneRunTick.apply(input(alive: false, adapterExists: true), to: run, existingLogLines: [])

        XCTAssertNil(outcome.run.bestIter)
    }
}
