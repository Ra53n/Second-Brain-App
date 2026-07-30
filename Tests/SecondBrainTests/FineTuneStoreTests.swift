// FineTuneStoreTests.swift — задача 81: персистентность finetune-runs.json (P2).
//
// Round-trip через persistNow()/второй стор, карантин битого файла, миграция
// минимального JSON, безопасный дефолт незнакомого статуса, кап истории,
// normalize() зависшего running с мёртвым pid.

import XCTest
@testable import SecondBrain

@MainActor
final class FineTuneStoreTests: XCTestCase {
    var tempDir: URL!
    var url: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-FineTune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        url = tempDir.appendingPathComponent("finetune-runs.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> FineTuneStore {
        FineTuneStore(url: url)
    }

    private func makeRun(model: String = "mlx-community/Qwen2.5-7B-Instruct-4bit") -> FineTuneRun {
        FineTuneRun(workdir: ".", datasetTitle: "finetune", model: model,
                   hyperparameters: FineTuneHyperparameters(), logPath: "runs/train.log",
                   adapterPath: "adapters")
    }

    /// Гарантированно мёртвый pid: дожидаемся завершения дочернего процесса и
    /// переиспользуем его pid — он уже пожат нами, повторно им никто не пользуется
    /// за время теста.
    private func deadPid() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    // MARK: - Round-trip

    func testRoundTripThroughPersistNowAndSecondStore() {
        var run = makeRun()
        run.points = [FineTuneProgressPoint(iter: 1, kind: .val, loss: 2.137, itPerSec: nil, peakMemGB: nil)]
        run.bestIter = 1
        run.status = .finished
        run.finishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        run.isAdoptedExternally = true

        let store = makeStore()
        store.appendRun(run)
        store.persistNow()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.runs.count, 1)
        XCTAssertEqual(reloaded.runs.first, run)
    }

    func testCorruptFileIsQuarantinedAndStoreStartsEmpty() throws {
        try Data("{ не json совсем".utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.runs, [])
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "битый файл уезжает в карантин")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Миграция

    /// Минимальный JSON старой версии — без любых полей, кроме model. Прогон не теряется.
    func testMigrationFromMinimalJSONKeepsRunWithDefaults() throws {
        try Data(#"{"runs":[{"model":"x"}]}"#.utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.runs.count, 1, "прогон не теряется при отсутствии полей")
        let run = store.runs[0]
        XCTAssertEqual(run.model, "x")
        XCTAssertEqual(run.workdir, ".")
        XCTAssertEqual(run.datasetTitle, "")
        XCTAssertEqual(run.hyperparameters, FineTuneHyperparameters())
        XCTAssertNil(run.pid)
        XCTAssertNil(run.finishedAt)
        XCTAssertEqual(run.points, [])
        XCTAssertNil(run.bestIter)
        XCTAssertEqual(run.logPath, "")
        XCTAssertEqual(run.adapterPath, "")
    }

    /// Незнакомое поле isAdoptedExternally (задача 81, доработка) — старый JSON без
    /// него грузит "свой" прогон, не "чужой".
    func testMigrationDefaultsIsAdoptedExternallyToFalse() throws {
        try Data(#"{"runs":[{"model":"x"}]}"#.utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.runs.first?.isAdoptedExternally, false)
    }

    /// Точка с незнакомым kind «из будущего» выпадает целиком — подмена вида
    /// (например на .train) исказила бы график и выбор чекпоинта.
    func testFuturePointKindIsDroppedNotDefaulted() throws {
        let json = """
        {"runs":[{"model":"x","points":[\
        {"iter":1,"kind":"val","loss":1.0},\
        {"iter":2,"kind":"forecast","loss":0.5},\
        {"iter":3,"kind":"train","loss":0.9,"itPerSec":0.1}]}]}
        """
        try Data(json.utf8).write(to: url)
        let store = makeStore()
        let points = store.runs.first?.points ?? []
        XCTAssertEqual(points.map(\.iter), [1, 3], "точка с kind:\"forecast\" выпадает, остальные целы")
    }

    /// Незнакомый статус «из будущего» — безопасный дефолт .interrupted, НЕ .running
    /// (running тянул бы за собой сигналы процессу на прогоне, который никто не запускал).
    func testUnknownFutureStatusDecodesToSafeDefault() throws {
        try Data(#"{"runs":[{"model":"x","status":"queued"}]}"#.utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.runs[0].status, .interrupted,
                       "незнакомый статус должен декодироваться в безопасный дефолт, не в .running")
    }

    // MARK: - Кап истории

    func testRunsCapEvictsOldest() {
        let store = makeStore()
        for i in 0..<(FineTuneStore.runsCap + 5) {
            var run = makeRun()
            run.datasetTitle = "run-\(i)"
            store.appendRun(run)
        }
        XCTAssertEqual(store.runs.count, FineTuneStore.runsCap)
        XCTAssertEqual(store.runs.first?.datasetTitle, "run-\(FineTuneStore.runsCap + 4)",
                       "новые — в начале")
        XCTAssertEqual(store.runs.last?.datasetTitle, "run-5", "старейшие вытеснены")
    }

    // MARK: - normalize()

    func testNormalizeInterruptsRunningWithDeadPid() throws {
        var running = makeRun()
        running.status = .running
        running.pid = deadPid()
        let document = FineTuneDocument(runs: [running])
        FineTunePersistence.save(document, to: url)

        let store = makeStore()
        let normalized = store.runs.first { $0.id == running.id }
        XCTAssertEqual(normalized?.status, .interrupted,
                       "зависший running без живого процесса — прерван при старте")
        XCTAssertNotNil(normalized?.finishedAt)

        // Нормализация зафиксирована на диске синхронно.
        let onDisk = FineTunePersistence.loadDocument(from: url)
        XCTAssertEqual(onDisk.runs.first?.status, .interrupted)
    }

    func testNormalizeLeavesRunningWithLivePidUntouched() throws {
        var running = makeRun()
        running.status = .running
        running.pid = getpid()
        let document = FineTuneDocument(runs: [running])
        FineTunePersistence.save(document, to: url)

        let store = makeStore()
        XCTAssertEqual(store.runs.first?.status, .running, "живой pid — не трогаем при старте")
    }

    /// pid 0 (недописанный run.json) — kill(0,0) отвечает 0 (группа приложения),
    /// что без guard'а выглядело бы как живой прогон навсегда.
    func testNormalizeInterruptsRunningWithPidZero() throws {
        var running = makeRun()
        running.status = .running
        running.pid = 0
        let document = FineTuneDocument(runs: [running])
        FineTunePersistence.save(document, to: url)

        let store = makeStore()
        XCTAssertEqual(store.runs.first?.status, .interrupted, "pid 0 не должен считаться живым")
    }

    func testNormalizeLeavesFinishedRunsUntouched() throws {
        var finished = makeRun()
        finished.status = .finished
        let document = FineTuneDocument(runs: [finished])
        FineTunePersistence.save(document, to: url)

        let store = makeStore()
        XCTAssertEqual(store.runs.first?.status, .finished)
    }

    // MARK: - updateRun / latestRun

    func testUpdateRunMutatesAndPersists() {
        let run = makeRun()
        let store = makeStore()
        store.appendRun(run)
        let updated = store.updateRun(id: run.id) { $0.status = .stopped }
        XCTAssertTrue(updated)
        XCTAssertEqual(store.runs.first?.status, .stopped)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.runs.first?.status, .stopped)
    }

    func testUpdateRunUnknownIDReturnsFalse() {
        let store = makeStore()
        XCTAssertFalse(store.updateRun(id: UUID()) { $0.status = .stopped })
    }

    func testLatestRunReturnsNewestForWorkdir() {
        let store = makeStore()
        var first = makeRun()
        first.workdir = "dictation"
        first.datasetTitle = "первый"
        var second = makeRun()
        second.workdir = "dictation"
        second.datasetTitle = "второй"
        store.appendRun(first)
        store.appendRun(second)
        store.appendRun(makeRun()) // workdir "." — чужой
        XCTAssertEqual(store.latestRun(workdir: "dictation")?.datasetTitle, "второй")
    }
}
