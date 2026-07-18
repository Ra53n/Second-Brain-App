// PipelineSchedulingTests.swift — чистая решающая логика планировщика
// (задача 36): duePipelines (совпадение минуты, disabled/manual игнорируются,
// дедуп по scheduledFor), catchUpDecision (все ветки + идемпотентность).
// Без таймеров: только мок-даты.

import XCTest
@testable import SecondBrain

final class PipelineSchedulingTests: XCTestCase {
    private var moscow: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int,
                      second: Int = 0) -> Date {
        moscow.date(from: DateComponents(year: y, month: mo, day: d,
                                         hour: h, minute: mi, second: second))!
    }

    private func cronPipeline(_ expression: String, enabled: Bool = true,
                              catchUp: Bool = false, createdAt: Date? = nil) -> PipelineConfig {
        var p = PipelineConfig(name: "p")
        p.trigger = .cron(expression: expression)
        p.enabled = enabled
        p.catchUpOnStart = catchUp
        if let createdAt { p.createdAt = createdAt }
        return p
    }

    // MARK: - duePipelines

    func testDueMatchesMinuteAndTruncatesSeconds() {
        let pipeline = cronPipeline("*/5 * * * *")
        let due = PipelineScheduling.duePipelines([pipeline], latestRun: { _ in nil },
                                                  now: date(2026, 7, 18, 10, 5, second: 37),
                                                  calendar: moscow)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due[0].slot, date(2026, 7, 18, 10, 5), "слот — минута без секунд")
    }

    func testDueSkipsNonMatchingDisabledAndManual() {
        let matching = cronPipeline("0 9 * * *")
        let wrongMinute = cronPipeline("30 9 * * *")
        let disabled = cronPipeline("0 9 * * *", enabled: false)
        var manual = PipelineConfig(name: "manual")
        manual.trigger = .manual
        let broken = cronPipeline("не крон")

        let due = PipelineScheduling.duePipelines(
            [matching, wrongMinute, disabled, manual, broken],
            latestRun: { _ in nil },
            now: date(2026, 7, 18, 9, 0), calendar: moscow)
        XCTAssertEqual(due.map { $0.pipeline.id }, [matching.id])
    }

    func testDueDedupsBySlotInHistory() {
        let pipeline = cronPipeline("0 9 * * *")
        let slot = date(2026, 7, 18, 9, 0)
        var recorded = PipelineRun(pipelineID: pipeline.id, trigger: .cron)
        recorded.scheduledFor = slot

        // Слот уже отражён в истории (двойной тик/рестарт в ту же минуту).
        let due = PipelineScheduling.duePipelines([pipeline],
                                                  latestRun: { _ in recorded },
                                                  now: slot, calendar: moscow)
        XCTAssertTrue(due.isEmpty, "прогон этого слота уже записан")

        // Другой слот — срабатывает.
        var oldRun = PipelineRun(pipelineID: pipeline.id, trigger: .cron)
        oldRun.scheduledFor = date(2026, 7, 17, 9, 0)
        let dueNext = PipelineScheduling.duePipelines([pipeline],
                                                      latestRun: { _ in oldRun },
                                                      now: slot, calendar: moscow)
        XCTAssertEqual(dueNext.count, 1)
    }

    // MARK: - catchUpDecision

    func testCatchUpNoneWhenSlotInFuture() {
        // Последний прогон был в 9:00, следующий слот завтра — пропуска нет.
        let pipeline = cronPipeline("0 9 * * *", catchUp: true)
        var latest = PipelineRun(pipelineID: pipeline.id, trigger: .cron)
        latest.scheduledFor = date(2026, 7, 18, 9, 0)
        let decision = PipelineScheduling.catchUpDecision(
            pipeline: pipeline, latestRun: latest,
            now: date(2026, 7, 18, 10, 0), calendar: moscow)
        XCTAssertEqual(decision, .none)
    }

    func testCatchUpMissedOnlyWhenFlagOff() {
        // Слот 9:00 прошёл, пока приложение не работало; флаг выключен.
        let pipeline = cronPipeline("0 9 * * *")
        var latest = PipelineRun(pipelineID: pipeline.id, trigger: .cron)
        latest.scheduledFor = date(2026, 7, 17, 9, 0)
        let decision = PipelineScheduling.catchUpDecision(
            pipeline: pipeline, latestRun: latest,
            now: date(2026, 7, 18, 12, 0), calendar: moscow)
        XCTAssertEqual(decision, .missedOnly(slot: date(2026, 7, 18, 9, 0)))
    }

    func testCatchUpRunWhenFlagOn() {
        let pipeline = cronPipeline("0 9 * * *", catchUp: true)
        var latest = PipelineRun(pipelineID: pipeline.id, trigger: .cron)
        latest.scheduledFor = date(2026, 7, 17, 9, 0)
        let decision = PipelineScheduling.catchUpDecision(
            pipeline: pipeline, latestRun: latest,
            now: date(2026, 7, 18, 12, 0), calendar: moscow)
        XCTAssertEqual(decision, .runCatchUp(slot: date(2026, 7, 18, 9, 0)))
    }

    func testCatchUpExactlyOneSlotEvenAfterLongDowntime() {
        // Неделя простоя → догоняется РОВНО один слот (первый после якоря).
        let pipeline = cronPipeline("0 9 * * *", catchUp: true)
        var latest = PipelineRun(pipelineID: pipeline.id, trigger: .cron)
        latest.scheduledFor = date(2026, 7, 10, 9, 0)
        let decision = PipelineScheduling.catchUpDecision(
            pipeline: pipeline, latestRun: latest,
            now: date(2026, 7, 18, 12, 0), calendar: moscow)
        XCTAssertEqual(decision, .runCatchUp(slot: date(2026, 7, 11, 9, 0)))
    }

    func testCatchUpIdempotentWhenSlotAlreadyRecorded() {
        // Рестарт после уже записанного missed того же слота — дублей нет.
        let pipeline = cronPipeline("0 9 * * *", catchUp: true)
        var latest = PipelineRun(pipelineID: pipeline.id, trigger: .cron)
        latest.scheduledFor = date(2026, 7, 18, 9, 0)
        latest.status = .missed
        let decision = PipelineScheduling.catchUpDecision(
            pipeline: pipeline, latestRun: latest,
            now: date(2026, 7, 18, 9, 30), calendar: moscow)
        XCTAssertEqual(decision, .none)
    }

    func testCatchUpAnchorsToCreatedAtWithoutHistory() {
        // Истории нет — якорь createdAt: слот после создания, но до now.
        let pipeline = cronPipeline("0 9 * * *", catchUp: true,
                                    createdAt: date(2026, 7, 17, 15, 0))
        let decision = PipelineScheduling.catchUpDecision(
            pipeline: pipeline, latestRun: nil,
            now: date(2026, 7, 18, 12, 0), calendar: moscow)
        XCTAssertEqual(decision, .runCatchUp(slot: date(2026, 7, 18, 9, 0)))
    }

    func testCatchUpNoneForDisabledOrManual() {
        let disabled = cronPipeline("0 9 * * *", enabled: false, catchUp: true,
                                    createdAt: date(2026, 7, 1, 0, 0))
        XCTAssertEqual(PipelineScheduling.catchUpDecision(
            pipeline: disabled, latestRun: nil,
            now: date(2026, 7, 18, 12, 0), calendar: moscow), .none)

        var manual = PipelineConfig(name: "manual")
        manual.trigger = .manual
        manual.catchUpOnStart = true
        XCTAssertEqual(PipelineScheduling.catchUpDecision(
            pipeline: manual, latestRun: nil,
            now: date(2026, 7, 18, 12, 0), calendar: moscow), .none)
    }

    func testCatchUpAnchorsToStartedAtForManualLatestRun() {
        // Последний прогон был ручным (scheduledFor nil) — якорь его startedAt.
        let pipeline = cronPipeline("0 9 * * *", catchUp: true)
        var latest = PipelineRun(pipelineID: pipeline.id, trigger: .manual)
        latest.startedAt = date(2026, 7, 17, 20, 0)
        let decision = PipelineScheduling.catchUpDecision(
            pipeline: pipeline, latestRun: latest,
            now: date(2026, 7, 18, 12, 0), calendar: moscow)
        XCTAssertEqual(decision, .runCatchUp(slot: date(2026, 7, 18, 9, 0)))
    }
}
