// FineTuneViewModel.swift — единственный владелец состояния раздела «Тюнинг».
//
// Гонки (P5): runGen — жизненный цикл прогона (start/tick), отдельно от него
// environmentGen/datasetsGen/examplesGen — проверка окружения и сканирование
// каталогов/примеров не отменяют друг друга. Сканирование и разбор — на фоновой
// очереди (Task.detached), публикация результата — на MainActor. Живой лог
// дочитывается таймером раз в секунду (FineTuneLogTail сам таймер не заводит).

import Foundation

/// Причина пустого/непустого списка датасетов — различима на экране без
/// разбора errorText (antipattern 5): его же пишут start()/stopCurrent()/installBest().
enum FineTuneDatasetsState: Equatable {
    case noRepo
    case noDirectory
    case empty
    case ready
}

@MainActor
final class FineTuneViewModel: ObservableObject {
    @Published var datasets: [FineTuneDataset] = []
    @Published var datasetsState: FineTuneDatasetsState = .noRepo
    /// nil — окружение ещё не проверялось.
    @Published var environmentReady: Bool?
    @Published var examples: [FineTuneExample] = []
    @Published var taskTypeFilter: String?
    @Published var logTail: String = ""
    @Published var statusText: String = ""
    @Published var errorText: String?
    /// id прогона, который сейчас реально тайлится — лог/статус в UI показываются
    /// только для него (В4): у ViewModel один хвост лога на все прогоны сразу.
    @Published private(set) var tailedRunID: UUID?

    nonisolated static let defaultModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    private static let logTailLimit = 200

    private let store: FineTuneStore
    private let runner: FineTuneRunner
    private let fineTuneRoot: () -> URL?

    private var runGen = 0
    private var environmentGen = 0
    private var datasetsGen = 0
    private var examplesGen = 0
    private var tailTimer: Timer?
    private var tail: FineTuneLogTail?
    /// Кольцевой буфер отображаемого хвоста лога — readNew() отдаёт только НОВЫЙ
    /// кусок, без накопления панель схлопывалась бы до последней строки.
    private var logLines: [String] = []
    private var isTicking = false

    init(store: FineTuneStore, runner: FineTuneRunner, fineTuneRoot: @escaping () -> URL?) {
        self.store = store
        self.runner = runner
        self.fineTuneRoot = fineTuneRoot
    }

    /// Repeating-таймер сам себя не гасит: run loop держит его вечно, даже когда
    /// замыкание внутри поймало ViewModel только через weak self.
    deinit { tailTimer?.invalidate() }

    func refreshDatasets() async {
        guard let root = fineTuneRoot() else {
            datasets = []
            datasetsState = .noRepo
            return
        }
        // Репозиторий выбран, но каталога finetune/ в нём нет — отдельная от
        // «нет датасетов» подсказка (собрать датасет из vault, а не «нет репозитория»).
        guard FileManager.default.fileExists(atPath: root.path) else {
            datasets = []
            datasetsState = .noDirectory
            return
        }
        datasetsGen += 1
        let gen = datasetsGen
        let scanned = await Task.detached { FineTuneDatasetScanner.scan(fineTuneRoot: root) }.value
        guard gen == datasetsGen else { return }
        datasets = scanned
        datasetsState = scanned.isEmpty ? .empty : .ready
        await adoptRunning(datasets: scanned, gen: gen)
    }

    func checkEnvironment() async {
        guard let root = fineTuneRoot() else {
            environmentReady = false
            return
        }
        environmentGen += 1
        let gen = environmentGen
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = MCPEnv.augmentedPATH(extra: environment["PATH"] ?? "")
        let candidates = FineTuneEnvironment.candidates(fineTuneRoot: root, environment: environment)
        let ready = await Task.detached { candidates.contains { FineTuneEnvironment.probe($0) } }.value
        guard gen == environmentGen else { return }
        // Подсказку показывает environmentBanner (FineTuneRunViews) напрямую по
        // environmentReady — errorText сюда не пишем, иначе каждый вход в раздел
        // затирал бы ошибку последней операции (stop/installBest).
        environmentReady = ready
    }

    func loadExamples(dataset: FineTuneDataset) async {
        let trainURL = dataset.dataURL.appendingPathComponent("train.jsonl")
        let metaURL = dataset.dataURL.appendingPathComponent("train.meta.jsonl")
        let hasMeta = FileManager.default.fileExists(atPath: metaURL.path)
        let filter = taskTypeFilter
        examplesGen += 1
        let gen = examplesGen
        let all = await Task.detached {
            FineTuneDatasetScanner.examples(dataURL: trainURL, metaURL: hasMeta ? metaURL : nil)
        }.value
        guard gen == examplesGen else { return }
        examples = filter.map { f in all.filter { $0.meta?.taskType == f } } ?? all
    }

    func start(dataset: FineTuneDataset, model: String, hyperparameters: FineTuneHyperparameters) async {
        runGen += 1
        let gen = runGen
        errorText = nil
        do {
            let run = try await runner.start(dataset: dataset, model: model, hyperparameters: hyperparameters)
            guard gen == runGen else { return }
            store.appendRun(run)
            statusText = "Тюн запущен, pid \(run.pid.map(String.init(_:)) ?? "?")"
            startTailing(run: run)
        } catch {
            guard gen == runGen else { return }
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Работает над ПОКАЗАННЫМ прогоном (параметр — тот, что выбран в UI), не над
    /// tailedRunID: тайлинг мог не завершиться подхватом (adopt() не нашёл своей
    /// записи, refreshDatasets ушла в .noRepo/.noDirectory) — тогда кнопка «Остановить»,
    /// включённая по стору, тихо no-op'ала бы.
    func stopCurrent(run: FineTuneRun) async {
        let result = await runner.stop(workdir: run.workdir)
        guard result.status == 0 else {
            errorText = "Не удалось остановить тюн: \(result.output)"
            return
        }
        errorText = nil
        store.updateRun(id: run.id) { existing in
            existing.status = .stopped
            existing.finishedAt = Date()
        }
        statusText = "Остановлено"
        if tailedRunID == run.id { stopTailing() }
    }

    /// Работает над ПОКАЗАННЫМ прогоном (параметр — тот, что выбран в UI), не над
    /// tailedRunID: иначе кнопка тихо no-op'ает на любом прогоне, кроме тайлящегося.
    func installBest(run: FineTuneRun) async {
        let result = await runner.installBest(workdir: run.workdir)
        guard result.status == 0 else {
            errorText = "Не удалось установить лучший чекпоинт: \(result.output)"
            return
        }
        errorText = nil
        statusText = result.output.isEmpty ? "Лучший чекпоинт установлен" : result.output
    }

    /// Таймер 1 с: mlx-lm дописывает лог реже (~11 с), но секундный опрос дешёв и не мигает UI.
    /// private: единственные вызывающие — сама ViewModel (start/adopt/tick), иначе
    /// гарантия «readNew() не более одного вызова за раз» (FineTuneLogTail) не гарантия.
    private func startTailing(run: FineTuneRun) {
        tailedRunID = run.id
        tail = FineTuneLogTail(url: URL(fileURLWithPath: run.logPath))
        logLines = []
        logTail = ""
        tailTimer?.invalidate()
        tailTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.tick() }
        }
    }

    private func stopTailing() {
        tailTimer?.invalidate()
        tailTimer = nil
        tail = nil
        tailedRunID = nil
    }

    private var tailedRun: FineTuneRun? {
        guard let id = tailedRunID else { return nil }
        return store.runs.first { $0.id == id }
    }

    /// Подхват прогона: перезапуск приложения при «Оставить работать», либо прогон,
    /// запущенный вручную из терминала (в сторе записи нет). Регистрируем в реестре
    /// ТОЛЬКО когда workdir+pid совпадают с уже известной нашей ЖИВОЙ записью — иначе
    /// прогон чужой, и терминация приложения его никогда не коснётся (инвариант №2).
    private func adoptRunning(datasets: [FineTuneDataset], gen: Int) async {
        guard tailedRunID == nil else { return }
        for dataset in datasets {
            guard gen == datasetsGen else { return }
            guard let cliRun = await runner.adopt(dataset: dataset) else { continue }
            guard gen == datasetsGen, tailedRunID == nil else { return }

            let pid = Int32(clamping: cliRun.pid)
            // status == .running — иначе завершённая запись с переиспользованным
            // системой pid (BACKLOG 45) выглядела бы «своей» и её график (points)
            // стирался бы строкой ниже.
            let existing = store.runs.first { $0.workdir == dataset.workdir && $0.pid == pid
                && $0.status == .running }
            let runID: UUID
            let isForeign: Bool
            if let existing {
                runID = existing.id
                isForeign = existing.isAdoptedExternally
                // train.log этого прогона на месте — точки перечитываются с нуля
                // свежим FineTuneLogTail, старые (уже персистентные) не дублируем.
                store.updateRun(id: existing.id) { run in
                    run.status = .running
                    run.pid = pid
                    run.finishedAt = nil
                    run.points = []
                }
            } else {
                var adopted = FineTuneRun(workdir: dataset.workdir, datasetTitle: dataset.title,
                                          model: cliRun.model, hyperparameters: cliRun.config,
                                          logPath: cliRun.log, adapterPath: cliRun.adapterPath)
                adopted.pid = pid
                adopted.startedAt = cliRun.startedAt
                adopted.isAdoptedExternally = true
                store.appendRun(adopted)
                runID = adopted.id
                isForeign = true
            }
            if !isForeign {
                await runner.adoptIntoRegistry(workdir: dataset.workdir, pid: pid)
            }
            guard let run = store.runs.first(where: { $0.id == runID }) else { return }
            startTailing(run: run)
            statusText = "Подхвачен идущий прогон, pid \(pid)"
            return
        }
    }

    /// I/O здесь, решение — в FineTuneRunTick.apply (P1, покрыт тестами напрямую).
    private func tick() async {
        guard !isTicking, let id = tailedRunID, let tail, let run = tailedRun else { return }
        isTicking = true
        defer { isTicking = false }

        let gen = runGen
        let pid = run.pid
        let adapterPath = run.adapterPath
        let (text, alive, adapterExists) = await Task.detached {
            let text = tail.readNew()
            let alive = pid.map { $0 > 1 && kill($0, 0) == 0 } ?? false
            let exists = FileManager.default.fileExists(atPath: adapterPath + "/adapters.safetensors")
            return (text, alive, exists)
        }.value
        guard gen == runGen, tailedRunID == id else { return }

        let outcome = FineTuneRunTick.apply(
            .init(newLogText: text, isProcessAlive: alive, adapterExists: adapterExists,
                 logTailLimit: Self.logTailLimit),
            to: run, existingLogLines: logLines)
        if !text.isEmpty {
            logLines = outcome.logLines
            logTail = logLines.joined(separator: "\n")
            store.updateRun(id: id) { $0.points = outcome.run.points }
        }

        guard outcome.finished else { return }
        // Обнаружили смерть процесса извне — detach в реестре: переиспользование
        // этого pid системой позже не подставит terminateAll() под чужой процесс.
        await runner.markProcessFinished(workdir: run.workdir)
        store.updateRun(id: id) { $0 = outcome.run }
        statusText = outcome.run.status == .finished ? "Тюн завершён" : "Прогон упал — смотри лог"
        stopTailing()
    }
}
