// PipelineStoreTests.swift — персистентность пайплайнов (задача 36):
// round-trip двух файлов, карантин битого файла, кап истории, normalize
// зависших running → error, каскадная чистка при удалении пайплайна.

import XCTest
@testable import SecondBrain

@MainActor
final class PipelineStoreTests: XCTestCase {
    var tempDir: URL!
    var pipelinesURL: URL!
    var runsURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        pipelinesURL = tempDir.appendingPathComponent("pipelines.json")
        runsURL = tempDir.appendingPathComponent("pipeline-runs.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> PipelineStore {
        PipelineStore(pipelinesURL: pipelinesURL, runsURL: runsURL)
    }

    func testRoundTripBothFiles() {
        var pipeline = PipelineConfig(name: "Дайджест")
        pipeline.trigger = .cron(expression: "0 9 * * *")
        let store = makeStore()
        store.add(pipeline)
        store.prWatchState[pipeline.id] = PRWatchState(lastSeenPRNumbers: [1, 2])
        var run = PipelineRun(pipelineID: pipeline.id, trigger: .manual)
        run.status = .ok
        run.finishedAt = run.startedAt
        store.appendRun(run)
        store.persistNow()

        // Второй стор читает то же состояние с диска.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.pipelines, [pipeline])
        XCTAssertEqual(reloaded.prWatchState[pipeline.id]?.lastSeenPRNumbers, [1, 2])
        XCTAssertEqual(reloaded.runs, [run])
    }

    func testCorruptFilesQuarantined() throws {
        try Data("{ не json".utf8).write(to: pipelinesURL)
        try Data("[ мусор".utf8).write(to: runsURL)
        let store = makeStore()
        XCTAssertEqual(store.pipelines, [])
        XCTAssertEqual(store.runs, [])
        for url in [pipelinesURL!, runsURL!] {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                          "битый файл уезжает в карантин, не теряется")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testDocumentMigrationFromMinimalJSON() throws {
        // Документ «старой версии»: только массив конфигов, без prWatchState.
        let json = #"{"pipelines": [{"name": "Старый"}]}"#
        try Data(json.utf8).write(to: pipelinesURL)
        let store = makeStore()
        XCTAssertEqual(store.pipelines.count, 1)
        XCTAssertEqual(store.pipelines[0].name, "Старый")
        XCTAssertEqual(store.prWatchState, [:])
    }

    func testRunsCapEvictsOldest() {
        let store = makeStore()
        let pipelineID = UUID()
        for i in 0..<(PipelineStore.runsCap + 5) {
            var run = PipelineRun(pipelineID: pipelineID, trigger: .cron)
            run.errorText = "run-\(i)"
            store.appendRun(run)
        }
        XCTAssertEqual(store.runs.count, PipelineStore.runsCap)
        // Новые в начале, старейшие (run-0…run-4) вытеснены.
        XCTAssertEqual(store.runs.first?.errorText, "run-\(PipelineStore.runsCap + 4)")
        XCTAssertEqual(store.runs.last?.errorText, "run-5")
    }

    func testNormalizeRunningToErrorOnLoad() {
        let pipelineID = UUID()
        var running = PipelineRun(pipelineID: pipelineID, trigger: .cron)
        running.status = .running
        var finished = PipelineRun(pipelineID: pipelineID, trigger: .manual)
        finished.status = .ok
        finished.finishedAt = finished.startedAt
        PipelinePersistence.save([running, finished], to: runsURL)

        let store = makeStore()
        let normalized = store.runs.first { $0.id == running.id }
        XCTAssertEqual(normalized?.status, .error,
                       "зависший running после рестарта → error (прогон не возобновляем)")
        XCTAssertEqual(normalized?.errorText, "Прерван рестартом приложения.")
        XCTAssertEqual(normalized?.finishedAt, running.startedAt)
        XCTAssertEqual(store.runs.first { $0.id == finished.id }?.status, .ok,
                       "завершённые не трогаем")
        // Нормализация сразу зафиксирована на диске.
        let onDisk = PipelinePersistence.loadRuns(from: runsURL)
        XCTAssertEqual(onDisk.first { $0.id == running.id }?.status, .error)
    }

    func testRemoveCascadesRunsAndWatchState() {
        var pipeline = PipelineConfig(name: "PR-watch")
        pipeline.trigger = .prWatch(owner: "o", repo: "r", pollIntervalMin: 5)
        let store = makeStore()
        store.add(pipeline)
        store.prWatchState[pipeline.id] = PRWatchState(lastSeenPRNumbers: [7])
        store.appendRun(PipelineRun(pipelineID: pipeline.id, trigger: .prWatch))
        let other = PipelineConfig(name: "Другой")
        store.add(other)
        store.appendRun(PipelineRun(pipelineID: other.id, trigger: .manual))

        store.remove(id: pipeline.id)
        XCTAssertEqual(store.pipelines.map(\.id), [other.id])
        XCTAssertEqual(store.runs.map(\.pipelineID), [other.id],
                       "прогоны удалённого пайплайна каскадно вычищены")
        XCTAssertNil(store.prWatchState[pipeline.id])
    }

    func testLatestRunReturnsNewest() {
        let store = makeStore()
        let pipelineID = UUID()
        var first = PipelineRun(pipelineID: pipelineID, trigger: .cron)
        first.errorText = "первый"
        var second = PipelineRun(pipelineID: pipelineID, trigger: .cron)
        second.errorText = "второй"
        store.appendRun(first)
        store.appendRun(second)
        store.appendRun(PipelineRun(pipelineID: UUID(), trigger: .manual)) // чужой
        XCTAssertEqual(store.latestRun(pipelineID: pipelineID)?.errorText, "второй")
    }
}
