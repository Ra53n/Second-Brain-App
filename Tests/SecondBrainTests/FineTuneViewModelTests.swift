// FineTuneViewModelTests.swift — задача 81 (доработка, второй круг): подхват прогона
// (в т.ч. не резюрекция завершённой записи с переиспользованным pid, В3), «взять лучший
// чекпоинт»/«остановить» на ПОКАЗАННОМ прогоне, а не на внутреннем tailedRunID (В2),
// неуспешные stop/installBest не лгут об успехе. Реальный Process не запускается —
// CLIRunner инжектирован.
//
// Задача 83 дополняет: snapshotBaseline() блокируется при идущем тюне без обращения к раннеру.
// Ревью 83: поздний результат раннера после cancelBaselineSnapshot не воскрешает
// isSnapshottingBaseline; generateCriteria на пустом датасете; saveCriteria сбрасывает
// criteriaGenErrorText на успехе.

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

    // MARK: - snapshotBaseline() блокируется при идущем тюне (задача 83)

    /// mlx не тянет тюн и baseline одновременно — раннер вообще не зовём, дорогой
    /// процесс не должен стартовать ради заведомо отклонённой попытки.
    func testSnapshotBaselineBlockedWhileTuneIsRunningDoesNotCallRunner() async {
        let store = makeStore()
        var running = makeRun(workdir: ".")
        running.status = .running
        store.appendRun(running)
        var runnerCalled = false
        let runner = FineTuneRunner(fineTuneRoot: nil, baselineCLI: { _ in
            runnerCalled = true
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })
        let dataset = FineTuneDataset(id: ".", title: "finetune", workdir: ".", rootURL: tempDir,
                                      dataURL: tempDir.appendingPathComponent("data"),
                                      trainCount: 10, validCount: 2, split: nil, systemPromptPath: nil)

        await viewModel.snapshotBaseline(dataset: dataset)

        XCTAssertFalse(runnerCalled, "идёт тюн — раннер snapshotBaseline вообще не зовётся")
        XCTAssertFalse(viewModel.isSnapshottingBaseline)
        XCTAssertEqual(viewModel.baselineErrorText,
                       "Идёт обучение — mlx не потянет два процесса, дождитесь или остановите тюн.")
    }

    // MARK: - cancelBaselineSnapshot(): гонка с поздним результатом раннера (задача 83, ревью)

    /// Поколение (snapshotGen) сдвигается ДО остановки процесса — ответ ещё идущего
    /// runner.snapshotBaseline, пришедший ПОСЛЕ cancelBaselineSnapshot, не должен
    /// перезаписать isSnapshottingBaseline/baselineErrorText, выставленные отменой.
    func testCancelBaselineSnapshotIgnoresLateRunnerResult() async throws {
        try writeDataset()
        let store = makeStore()
        let box = FineTuneViewModelContinuationBox()
        // root обязателен: snapshotBaseline проверяет fineTuneRoot ДО инжектированного
        // CLI, с nil он вернулся бы сразу и continuation не поставился бы никогда.
        let runner = FineTuneRunner(fineTuneRoot: tempDir, baselineCLI: { _ in
            await withCheckedContinuation { box.continuation = $0 }
            return .init(status: 0, output: "готово")
        }, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { [tempDir] in tempDir })
        let dataset = makeDataset()

        let snapshotTask = Task { await viewModel.snapshotBaseline(dataset: dataset) }
        // Предохранитель от вечного спина: CLI не вызвался — падаем, а не висим.
        var spins = 0
        while box.continuation == nil {
            await Task.yield()
            spins += 1
            if spins > 2_000_000 {
                XCTFail("runner так и не дошёл до инжектированного baseline-CLI")
                snapshotTask.cancel()
                return
            }
        }
        XCTAssertTrue(viewModel.isSnapshottingBaseline)

        await viewModel.cancelBaselineSnapshot(dataset: dataset)
        XCTAssertFalse(viewModel.isSnapshottingBaseline)
        XCTAssertEqual(viewModel.baselineErrorText, "Снятие baseline отменено.")

        box.continuation?.resume()
        _ = await snapshotTask.value

        XCTAssertFalse(viewModel.isSnapshottingBaseline,
                       "поздний результат раннера не должен воскресить isSnapshottingBaseline")
        XCTAssertEqual(viewModel.baselineErrorText, "Снятие baseline отменено.",
                       "поздний результат не должен затирать текст отмены")
    }

    // MARK: - generateCriteria() / saveCriteria() (задача 83)

    private func makeDataset() -> FineTuneDataset {
        FineTuneDataset(id: ".", title: "finetune", workdir: ".", rootURL: tempDir,
                        dataURL: tempDir.appendingPathComponent("data"),
                        trainCount: 1, validCount: 1, split: nil, systemPromptPath: nil)
    }

    /// Генератор через инжектированный providers-провайдер (без сети): пишет
    /// criteria.md в rootURL датасета и обновляет criteriaText.
    func testGenerateCriteriaWritesFileAndUpdatesCriteriaText() async throws {
        try writeDataset()
        let store = makeStore()
        let runner = FineTuneRunner(fineTuneRoot: nil, registry: BackgroundProcessRegistry())
        let provider = MockChatProvider(responses: ["# Критерии\n\nсгенерировано"])
        let resolved = ResolvedChatProvider(provider: provider, model: "m",
                                            providerID: ProviderID(rawValue: "mock"), displayName: "Mock")
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { [tempDir] in tempDir },
                                          criteriaProviders: { [resolved] })

        await viewModel.generateCriteria(dataset: makeDataset())

        XCTAssertFalse(viewModel.isGeneratingCriteria)
        XCTAssertNil(viewModel.criteriaGenErrorText)
        XCTAssertEqual(viewModel.criteriaText, "# Критерии\n\nсгенерировано")
        let onDisk = try String(contentsOf: tempDir.appendingPathComponent("criteria.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "# Критерии\n\nсгенерировано")
    }

    /// Нет доступного провайдера — понятная ошибка в criteriaGenErrorText, файл не пишется.
    func testGenerateCriteriaWithNoProviderSetsErrorText() async throws {
        try writeDataset()
        let store = makeStore()
        let runner = FineTuneRunner(fineTuneRoot: nil, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { [tempDir] in tempDir })

        await viewModel.generateCriteria(dataset: makeDataset())

        XCTAssertFalse(viewModel.isGeneratingCriteria)
        XCTAssertEqual(viewModel.criteriaGenErrorText, FineTuneError.noChatProvider.errorDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("criteria.md").path))
    }

    /// saveCriteria — редактор пишет тот же файл и перечитывает его обратно.
    func testSaveCriteriaRoundTrips() async throws {
        try writeDataset()
        let store = makeStore()
        let runner = FineTuneRunner(fineTuneRoot: nil, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { [tempDir] in tempDir })

        let ok = await viewModel.saveCriteria(dataset: makeDataset(), text: "# Правки вручную\n")

        XCTAssertTrue(ok)
        XCTAssertEqual(viewModel.criteriaText, "# Правки вручную\n")
        let onDisk = try String(contentsOf: tempDir.appendingPathComponent("criteria.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "# Правки вручную\n")
    }

    /// Ревью задачи 83: saveCriteria на успехе сбрасывает criteriaGenErrorText —
    /// иначе успешное сохранение из редактора не убирает баннер прошлой ошибки генерации.
    func testSaveCriteriaSuccessClearsCriteriaGenErrorText() async throws {
        try writeDataset()
        let store = makeStore()
        let runner = FineTuneRunner(fineTuneRoot: nil, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { [tempDir] in tempDir })
        viewModel.criteriaGenErrorText = "прошлая ошибка генерации"

        let ok = await viewModel.saveCriteria(dataset: makeDataset(), text: "# Правки\n")

        XCTAssertTrue(ok)
        XCTAssertNil(viewModel.criteriaGenErrorText)
    }

    /// Ревью задачи 83: пустой train.jsonl (нет примеров) — понятная ошибка без
    /// обращения к LLM.
    func testGenerateCriteriaOnEmptyDatasetSetsErrorWithoutCallingGenerator() async throws {
        // writeDataset() не зовём — train.jsonl отсутствует, examples() вернёт [].
        let store = makeStore()
        let runner = FineTuneRunner(fineTuneRoot: nil, registry: BackgroundProcessRegistry())
        var generatorCalled = false
        let provider = MockChatProvider(responses: ["не должно быть вызвано"])
        let resolved = ResolvedChatProvider(provider: provider, model: "m",
                                            providerID: ProviderID(rawValue: "mock"), displayName: "Mock")
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { [tempDir] in tempDir },
                                          criteriaProviders: { generatorCalled = true; return [resolved] })

        await viewModel.generateCriteria(dataset: makeDataset())

        XCTAssertFalse(viewModel.isGeneratingCriteria)
        XCTAssertEqual(viewModel.criteriaGenErrorText, "В датасете нет примеров — нечего анализировать.")
        XCTAssertFalse(generatorCalled, "провайдеры не должны запрашиваться без примеров")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("criteria.md").path))
    }
}

/// Тестовый мост для ручного управления моментом возврата инжектированного CLI —
/// `@unchecked Sendable`, доступ только последовательный (yield-цикл ждёт установки).
private final class FineTuneViewModelContinuationBox: @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Never>?
}
