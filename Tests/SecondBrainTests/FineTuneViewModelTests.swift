// FineTuneViewModelTests.swift — задача 81 (доработка, второй круг): подхват прогона
// (в т.ч. не резюрекция завершённой записи с переиспользованным pid, В3), «взять лучший
// чекпоинт»/«остановить» на ПОКАЗАННОМ прогоне, а не на внутреннем tailedRunID (В2),
// неуспешные stop/installBest не лгут об успехе. Реальный Process не запускается —
// CLIRunner инжектирован.

import XCTest
@testable import SecondBrain

@MainActor
final class FineTuneViewModelTests: XCTestCase {
    var tempDir: URL!
    var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-FineTuneVM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("finetune-runs.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeDataset() throws {
        let dataDir = tempDir.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let line = #"{"messages":[{"role":"system","content":"S"},{"role":"user","content":"U"},{"role":"assistant","content":"A"}]}"#
        try Data((line + "\n").utf8).write(to: dataDir.appendingPathComponent("train.jsonl"))
    }

    private func writeRunJSON(pid: Int32) throws {
        let runsDir = tempDir.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        let json = """
        {"pid": \(pid), "model": "m", "config": {}, "started_at": 1700000000.0, \
        "adapter_path": "adapters", "log": "runs/train.log"}
        """
        try Data(json.utf8).write(to: runsDir.appendingPathComponent("run.json"))
    }

    private func makeStore(runs: [FineTuneRun] = []) -> FineTuneStore {
        if !runs.isEmpty {
            FineTunePersistence.save(FineTuneDocument(runs: runs), to: storeURL)
        }
        return FineTuneStore(url: storeURL)
    }

    private func makeRun(workdir: String = ".", status: FineTuneRun.Status = .running) -> FineTuneRun {
        var run = FineTuneRun(workdir: workdir, datasetTitle: workdir, model: "m",
                              hyperparameters: FineTuneHyperparameters(), logPath: "runs/train.log",
                              adapterPath: "adapters")
        run.status = status
        return run
    }

    // MARK: - Подхват (Б1)

    /// workdir+pid совпадают с записью, оставленной нашим прошлым start() — регистрируем
    /// в реестре (гасится при выходе, как обычный свой прогон).
    func testRefreshDatasetsAdoptsOwnRunAndRegistersInRegistry() async throws {
        try writeDataset()
        try writeRunJSON(pid: getpid())
        var own = makeRun()
        own.pid = getpid()
        let store = makeStore(runs: [own])
        let registry = BackgroundProcessRegistry()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: registry)
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { [tempDir] in tempDir })

        await viewModel.refreshDatasets()

        XCTAssertEqual(registry.runningCount, 1, "свой прогон (совпал workdir+pid) регистрируется в реестре")
        XCTAssertEqual(store.runs.first?.isAdoptedExternally, false)
        XCTAssertEqual(store.runs.first?.status, .running)
    }

    /// Живой pid есть, но записи в сторе нет (запущен из терминала) — показываем в UI,
    /// но НЕ регистрируем: «чужой процесс не гасится никогда» (инвариант №2).
    func testRefreshDatasetsAdoptsForeignRunWithoutRegistering() async throws {
        try writeDataset()
        try writeRunJSON(pid: getpid())
        let store = makeStore()
        let registry = BackgroundProcessRegistry()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: registry)
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { [tempDir] in tempDir })

        await viewModel.refreshDatasets()

        XCTAssertEqual(registry.runningCount, 0, "чужой прогон в реестр не попадает")
        XCTAssertEqual(store.runs.count, 1, "прогон всё равно виден в UI")
        XCTAssertEqual(store.runs.first?.isAdoptedExternally, true)
        XCTAssertEqual(store.runs.first?.status, .running)
    }

    /// В3: переиспользованный системой pid (BACKLOG 45) не должен воскрешать ЗАВЕРШЁННУЮ
    /// запись с тем же workdir+pid — иначе её график (`points`) стирается строкой
    /// `run.points = []` в adoptRunning(), а статус тихо возвращается в .running.
    func testRefreshDatasetsDoesNotResurrectFinishedRunWithReusedPid() async throws {
        try writeDataset()
        try writeRunJSON(pid: getpid())
        var finished = makeRun(status: .finished)
        finished.pid = getpid()
        finished.points = [FineTuneProgressPoint(iter: 50, kind: .val, loss: 1.0, itPerSec: nil, peakMemGB: nil)]
        let store = makeStore(runs: [finished])
        let registry = BackgroundProcessRegistry()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: registry)
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { [tempDir] in tempDir })

        await viewModel.refreshDatasets()

        XCTAssertEqual(store.runs.count, 2, "живой pid из run.json — отдельная (внешняя) запись, не слияние")
        let finishedAfter = store.runs.first { $0.status == .finished }
        XCTAssertEqual(finishedAfter?.points.count, 1, "график завершённого прогона не стирается")
        XCTAssertTrue(store.runs.contains { $0.isAdoptedExternally && $0.status == .running },
                     "живой прогон виден отдельно как подхваченный извне")
    }

    /// Мёртвый pid из run.json — подхвата нет, датасет просто отображается штатно.
    func testRefreshDatasetsWithoutLiveRunDoesNothingSpecial() async throws {
        try writeDataset()
        let store = makeStore()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { [tempDir] in tempDir })

        await viewModel.refreshDatasets()

        XCTAssertEqual(viewModel.datasets.count, 1)
        XCTAssertEqual(store.runs.count, 0)
    }

    // MARK: - «Взять лучший чекпоинт» на показанном прогоне (Б2)

    /// installBest принимает прогон параметром — не зависит от tailedRunID
    /// (который здесь вообще не установлен ни разу за тест).
    func testInstallBestActsOnGivenRunNotActiveRun() async {
        let store = makeStore()
        let shownRun = makeRun(workdir: "dictation", status: .finished)
        store.appendRun(shownRun)

        var recordedWorkdir: String?
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { workdir, args in
            if args.contains("best") { recordedWorkdir = workdir }
            return .init(status: 0, output: "готово")
        }, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })

        await viewModel.installBest(run: shownRun)

        XCTAssertEqual(recordedWorkdir, "dictation", "операция идёт над показанным прогоном")
        XCTAssertEqual(viewModel.statusText, "готово")
        XCTAssertNil(viewModel.errorText)
    }

    func testInstallBestFailureSetsErrorTextNotStatus() async {
        let store = makeStore()
        let run = makeRun()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 1, output: "нет чекпоинтов") },
                                    registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })

        await viewModel.installBest(run: run)

        XCTAssertEqual(viewModel.errorText, "Не удалось установить лучший чекпоинт: нет чекпоинтов")
        XCTAssertNotEqual(viewModel.statusText, "нет чекпоинтов",
                          "провал не должен выглядеть обычным статусом (P6)")
    }

    // MARK: - stopCurrent(run:) не лжёт при неуспехе и не зависит от тайлинга (В2)

    func testStopCurrentFailureKeepsRunningStatusAndSetsErrorText() async {
        let store = makeStore()
        var run = makeRun()
        run.pid = getpid()
        store.appendRun(run)
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 1, output: "stop упал") },
                                    registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })

        await viewModel.stopCurrent(run: run)

        XCTAssertEqual(store.runs.first?.status, .running, "неуспешный stop не должен ставить .stopped")
        XCTAssertNotEqual(viewModel.statusText, "Остановлено")
        XCTAssertEqual(viewModel.errorText, "Не удалось остановить тюн: stop упал")
    }

    func testStopCurrentSuccessMarksStoppedAndClearsErrorText() async {
        let store = makeStore()
        var run = makeRun()
        run.pid = getpid()
        store.appendRun(run)
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })

        await viewModel.stopCurrent(run: run)

        XCTAssertEqual(store.runs.first?.status, .stopped)
        XCTAssertEqual(viewModel.statusText, "Остановлено")
        XCTAssertNil(viewModel.errorText)
    }

    /// В2: кнопка «Остановить» в UI включается по стору (`runs.first { status == .running }`),
    /// не по внутреннему tailedRunID — если подхват не отработал (adopt() не нашёл своей
    /// записи, refreshDatasets ушла в .noRepo/.noDirectory), тайлинг не стартовал вовсе,
    /// но stop обязан сработать над переданным прогоном, а не тихо no-op'ать.
    func testStopCurrentActsOnGivenRunWithoutTailingHavingEverStarted() async {
        let store = makeStore()
        var run = makeRun()
        run.pid = getpid()
        store.appendRun(run)
        var recordedWorkdir: String?
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { workdir, _ in
            recordedWorkdir = workdir
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })

        await viewModel.stopCurrent(run: run)

        XCTAssertEqual(recordedWorkdir, ".", "stop идёт над переданным прогоном независимо от тайлинга")
        XCTAssertEqual(store.runs.first?.status, .stopped)
    }
}
