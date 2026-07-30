// FineTuneRunnerTests.swift — задача 81: раннер CLI-тюнинга (actor, инвариант №2).
//
// Инжектированный CLIRunner — реальный Process не запускается. Отдельный экземпляр
// BackgroundProcessRegistry на тест (не .shared). Никогда не регистрируем pid,
// которому шлём реальные сигналы, — используем getpid() как "живой", детач перед
// любым сигналом. Живость процесса в реестре проверяется через registry.runningCount
// (что реально видит terminateAll()), не через приватное состояние актора.

import XCTest
@testable import SecondBrain

final class FineTuneRunnerTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-FineTuneRunner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDataset() -> FineTuneDataset {
        FineTuneDataset(id: ".", title: "finetune", workdir: ".", rootURL: tempDir,
                        dataURL: tempDir.appendingPathComponent("data"),
                        trainCount: 10, validCount: 2, split: nil, systemPromptPath: nil)
    }

    private func writeRunJSON(pid: Int, model: String = "m", log: String = "runs/train.log",
                              adapterPath: String = "adapters") throws {
        let runsDir = tempDir.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        let json = """
        {"pid": \(pid), "model": "\(model)", "config": {}, "started_at": 1700000000.0, \
        "adapter_path": "\(adapterPath)", "log": "\(log)"}
        """
        try Data(json.utf8).write(to: runsDir.appendingPathComponent("run.json"))
    }

    // MARK: - start()

    func testSuccessfulStartRegistersProcessAndReturnsRunningRun() async throws {
        let registry = BackgroundProcessRegistry()
        let dataset = makeDataset()
        let livePid = getpid()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { [weak self] _, _ in
            try? self?.writeRunJSON(pid: Int(livePid))
            return .init(status: 0, output: "")
        }, registry: registry)

        let run = try await runner.start(dataset: dataset, model: "m", hyperparameters: FineTuneHyperparameters())
        XCTAssertEqual(run.status, .running)
        XCTAssertEqual(run.pid, livePid)
        XCTAssertEqual(registry.runningCount, 1, "успешный старт регистрирует процесс в реестре")
    }

    /// Живой pid уже идёт (run.json существует до старта) — throw .alreadyRunning
    /// без обращения к CLI.
    func testStartWithLivePidThrowsAlreadyRunning() async throws {
        let dataset = makeDataset()
        let livePid = getpid()
        try writeRunJSON(pid: Int(livePid))
        var cliCalled = false
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in
            cliCalled = true
            return .init(status: 0, output: "")
        }, registry: BackgroundProcessRegistry())

        do {
            _ = try await runner.start(dataset: dataset, model: "m", hyperparameters: FineTuneHyperparameters())
            XCTFail("ожидался alreadyRunning")
        } catch {
            XCTAssertEqual(error as? FineTuneError, .alreadyRunning(pid: livePid))
        }
        XCTAssertFalse(cliCalled, "живой pid — CLI вообще не зовём")
    }

    func testNonZeroExitCodeThrowsStartFailedWithOutput() async {
        let dataset = makeDataset()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in
            .init(status: 1, output: "boom: mlx_lm not found")
        }, registry: BackgroundProcessRegistry())

        do {
            _ = try await runner.start(dataset: dataset, model: "m", hyperparameters: FineTuneHyperparameters())
            XCTFail("ожидался startFailed")
        } catch {
            XCTAssertEqual(error as? FineTuneError, .startFailed("boom: mlx_lm not found"))
        }
    }

    func testMissingRunJSONAfterSuccessfulExitThrowsStartFailed() async {
        let dataset = makeDataset()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in
            .init(status: 0, output: "") // успех, но run.json не пишем
        }, registry: BackgroundProcessRegistry())

        do {
            _ = try await runner.start(dataset: dataset, model: "m", hyperparameters: FineTuneHyperparameters())
            XCTFail("ожидался startFailed")
        } catch {
            XCTAssertEqual(error as? FineTuneError, .startFailed("run.json не найден после старта"))
        }
    }

    /// pid: 0 в run.json — защита от killpg(0,…): startFailed, процесс НЕ регистрируется.
    func testRunJSONWithPidZeroFailsStartWithoutRegistering() async throws {
        let registry = BackgroundProcessRegistry()
        let dataset = makeDataset()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { [weak self] _, _ in
            try? self?.writeRunJSON(pid: 0)
            return .init(status: 0, output: "")
        }, registry: registry)

        do {
            _ = try await runner.start(dataset: dataset, model: "m", hyperparameters: FineTuneHyperparameters())
            XCTFail("ожидался startFailed для pid 0")
        } catch {
            XCTAssertEqual(error as? FineTuneError, .startFailed("run.json вернул недопустимый pid 0"))
        }
        XCTAssertEqual(registry.runningCount, 0, "pid 0 не должен попасть в реестр")
    }

    // MARK: - adopt()

    func testAdoptOnDeadPidReturnsNil() async throws {
        let dataset = makeDataset()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        try writeRunJSON(pid: Int(process.processIdentifier))

        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: BackgroundProcessRegistry())
        let adopted = await runner.adopt(dataset: dataset)
        XCTAssertNil(adopted, "мёртвый pid из run.json — не идущий прогон")
    }

    func testAdoptOnPidOneReturnsNil() async throws {
        let dataset = makeDataset()
        try writeRunJSON(pid: 1)
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: BackgroundProcessRegistry())
        let adopted = await runner.adopt(dataset: dataset)
        XCTAssertNil(adopted, "pid 1 (launchd) никогда не наш прогон")
    }

    func testAdoptWithNoRunJSONReturnsNil() async {
        let dataset = makeDataset()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: BackgroundProcessRegistry())
        let adopted = await runner.adopt(dataset: dataset)
        XCTAssertNil(adopted)
    }

    func testAdoptOnLivePidReturnsCLIRun() async throws {
        let dataset = makeDataset()
        try writeRunJSON(pid: Int(getpid()), model: "qwen")
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: BackgroundProcessRegistry())
        let adopted = await runner.adopt(dataset: dataset)
        XCTAssertEqual(adopted?.pid, Int(getpid()))
        XCTAssertEqual(adopted?.model, "qwen")
    }

    // MARK: - adoptIntoRegistry() (Б1)

    func testAdoptIntoRegistryRegistersLivePid() async {
        let registry = BackgroundProcessRegistry()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: registry)
        let ok = await runner.adoptIntoRegistry(workdir: ".", pid: getpid())
        XCTAssertTrue(ok)
        XCTAssertEqual(registry.runningCount, 1)
    }

    func testAdoptIntoRegistryRejectsInvalidPid() async {
        let registry = BackgroundProcessRegistry()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: registry)
        let ok = await runner.adoptIntoRegistry(workdir: ".", pid: 0)
        XCTAssertFalse(ok, "pid ≤ 1 не регистрируется — killpg(0,…) бьёт по группе приложения")
        XCTAssertEqual(registry.runningCount, 0)
    }

    func testAdoptIntoRegistryIsIdempotentPerWorkdir() async {
        let registry = BackgroundProcessRegistry()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: registry)
        _ = await runner.adoptIntoRegistry(workdir: ".", pid: getpid())
        let second = await runner.adoptIntoRegistry(workdir: ".", pid: getpid())
        XCTAssertFalse(second, "тот же workdir уже отслеживается — повторная регистрация не нужна")
        XCTAssertEqual(registry.runningCount, 1, "процесс зарегистрирован в реестре ровно один раз")
    }

    // MARK: - markProcessFinished() (В10 — pid-recycling safety)

    func testMarkProcessFinishedDetachesTrackedProcess() async {
        let registry = BackgroundProcessRegistry()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { _, _ in .init(status: 0, output: "") },
                                    registry: registry)
        _ = await runner.adoptIntoRegistry(workdir: ".", pid: getpid())
        XCTAssertEqual(registry.runningCount, 1)

        await runner.markProcessFinished(workdir: ".")
        XCTAssertEqual(registry.runningCount, 0,
                       "detached — переиспользование этого pid системой не подставит terminateAll под чужой процесс")
    }

    // MARK: - detach / stop (инвариант №2: «оставить работать»)

    func testDetachAllFromQuitMakesLiveProcessNotRunning() async throws {
        let registry = BackgroundProcessRegistry()
        let dataset = makeDataset()
        let livePid = getpid()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { [weak self] _, _ in
            try? self?.writeRunJSON(pid: Int(livePid))
            return .init(status: 0, output: "")
        }, registry: registry)
        _ = try await runner.start(dataset: dataset, model: "m", hyperparameters: FineTuneHyperparameters())
        XCTAssertEqual(registry.runningCount, 1)

        await runner.detachAllFromQuit()
        XCTAssertEqual(registry.runningCount, 0, "«Оставить работать» — прогон больше не считается нашим")
    }

    func testStopWithSuccessClearsLiveProcessTracking() async throws {
        let registry = BackgroundProcessRegistry()
        let dataset = makeDataset()
        let livePid = getpid()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { [weak self] _, args in
            if args.contains("start") { try? self?.writeRunJSON(pid: Int(livePid)) }
            return .init(status: 0, output: "")
        }, registry: registry)
        _ = try await runner.start(dataset: dataset, model: "m", hyperparameters: FineTuneHyperparameters())
        let result = await runner.stop(workdir: dataset.workdir)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(registry.runningCount, 0, "успешный stop() снимает процесс с отслеживания")
    }

    /// Б3: неуспешный CLI stop не должен молча выглядеть как остановка — процесс мог
    /// остаться жить, поэтому отслеживание (и, значит, реестр) не трогаем.
    func testStopWithNonZeroExitKeepsProcessTracked() async throws {
        let registry = BackgroundProcessRegistry()
        let dataset = makeDataset()
        let livePid = getpid()
        let runner = FineTuneRunner(fineTuneRoot: nil, runCLI: { [weak self] _, args in
            if args.contains("start") {
                try? self?.writeRunJSON(pid: Int(livePid))
                return .init(status: 0, output: "")
            }
            return .init(status: 1, output: "stop упал")
        }, registry: registry)
        _ = try await runner.start(dataset: dataset, model: "m", hyperparameters: FineTuneHyperparameters())
        let result = await runner.stop(workdir: dataset.workdir)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(registry.runningCount, 1, "провалившийся stop — процесс всё ещё может быть жив")
    }
}

// MARK: - FineTuneCLIRun — снисходительный декодер run.json

final class FineTuneCLIRunTests: XCTestCase {

    func testLearningRateAsStringDecodesVerbatim() throws {
        let json = #"{"pid":100,"model":"m","config":{"learning_rate":"5e-6"},"started_at":0,"adapter_path":"a","log":"l"}"#
        let run = try JSONDecoder().decode(FineTuneCLIRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.config.learningRate, "5e-6")
    }

    /// val_batches на диске (4) — дрейф формата против нынешнего дефолта (-1).
    func testValBatchesDriftFromDiskOverridesDefault() throws {
        let json = #"{"pid":100,"model":"m","config":{"val_batches":4},"started_at":0,"adapter_path":"a","log":"l"}"#
        let run = try JSONDecoder().decode(FineTuneCLIRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.config.valBatches, 4)
    }

    /// started_at — эпоха с 1970 (time.time()), не с 2001: дата не должна уехать на десятилетия.
    func testStartedAtIsUnixEpochNotReferenceDate() throws {
        let json = #"{"pid":100,"model":"m","config":{},"started_at":1785351604.631804,"adapter_path":"a","log":"l"}"#
        let run = try JSONDecoder().decode(FineTuneCLIRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.startedAt.timeIntervalSince1970, 1785351604.631804, accuracy: 0.001)
        let year = Calendar(identifier: .gregorian).component(.year, from: run.startedAt)
        XCTAssertEqual(year, 2026, "интерпретация эпохи с 2001 увела бы дату на ~31 год")
    }

    func testMissingFieldsDecodeToDefaults() throws {
        let run = try JSONDecoder().decode(FineTuneCLIRun.self, from: Data("{}".utf8))
        XCTAssertEqual(run.pid, -1)
        XCTAssertEqual(run.model, "")
        XCTAssertEqual(run.config, FineTuneHyperparameters())
        XCTAssertEqual(run.startedAt, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(run.adapterPath, "")
        XCTAssertEqual(run.log, "")
    }

    /// pid строкой вместо числа: поле «не того» типа равносильно отсутствующему и
    /// уходит в дефолт, остальная запись выживает. Иначе один дрейфнувший ключ во
    /// внешнем run.json выглядел бы как отсутствующий файл — и живой прогон терялся.
    func testPidAsStringFallsBackWithoutLosingRecord() throws {
        let json = #"{"pid":"12345","model":"m","config":{},"started_at":0,"adapter_path":"a","log":"l"}"#
        let decoded = try JSONDecoder().decode(FineTuneCLIRun.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.pid, -1, "pid не того типа → дефолт, а не падение всего декода")
        XCTAssertEqual(decoded.model, "m", "остальные поля записи целы")
        XCTAssertEqual(decoded.log, "l")
    }

    /// Дрейф формата целиком: незнакомые ключи, пропуски и «не тот» тип разом.
    func testDriftedRunJSONStillDecodes() throws {
        let json = #"{"pid":4394,"model":"m","config":{"iters":"300","val_batches":4},"unknown":true}"#
        let decoded = try JSONDecoder().decode(FineTuneCLIRun.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.pid, 4394)
        XCTAssertEqual(decoded.config.iters, 300, "iters строкой → дефолт 300, а не срыв разбора")
        XCTAssertEqual(decoded.config.valBatches, 4, "дрейф val_batches (4 против нынешнего -1) читается как есть")
        XCTAssertEqual(decoded.adapterPath, "", "отсутствующее поле — дефолт")
    }
}
