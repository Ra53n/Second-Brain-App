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
    /// Ошибка start()/stopCurrent()/installBest() — про прогон, не про валидацию
    /// датасета (см. `validationErrorText`, разведены ревью задачи 82: общий errorText
    /// прятал результат последней проверки под «не удалось остановить тюн»).
    @Published var errorText: String?
    /// Ошибка именно validate() — сам процесс не запустился/завис (P6, отдельно от
    /// результата проверки, который лежит в FineTuneStore и не про сбой приложения).
    @Published var validationErrorText: String?
    /// id прогона, который сейчас реально тайлится — лог/статус в UI показываются
    /// только для него (В4): у ViewModel один хвост лога на все прогоны сразу.
    @Published private(set) var tailedRunID: UUID?
    /// Кнопка «Проверить датасет» блокируется, пока true (второй параллельный запуск не нужен).
    @Published private(set) var isValidating = false
    @Published private(set) var baselineSnapshot: FineTuneOutputsReader.Snapshot?
    /// Идёт `baseline.py` (задача 83) — отдельно от `isValidating`, кнопки независимы.
    @Published private(set) var isSnapshottingBaseline = false
    /// Ошибка снятия baseline: провал самого процесса или guard «идёт тюн» (P6).
    @Published var baselineErrorText: String?
    @Published private(set) var criteriaText: String?
    /// Генерация criteria.md через LLM (задача 83) — отдельно от isValidating/isSnapshottingBaseline.
    @Published private(set) var isGeneratingCriteria = false
    @Published var criteriaGenErrorText: String?
    /// Превью разбора файла, выбранного в sheet «Добавить датасет» (задача 83).
    @Published private(set) var importPreview: FineTuneImportCore.ParseResult?
    @Published var importErrorText: String?
    @Published private(set) var isImporting = false
    /// run.json на диске для датасета, обновляемого экраном «Прогоны» — источник
    /// guard'а `isCurrentRun` (задача 92): run.json/train.log — синглтоны на workdir,
    /// следующий тюн их перезаписывает без ведома FineTuneStore.
    @Published private(set) var currentCLIRun: FineTuneCLIRun?
    private var currentCLIRunDataset: FineTuneDataset?

    nonisolated static let defaultModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    /// Пресет прогона/базы чата (задача 92): малая база рядом с прежней 7B.
    nonisolated static let smallModel = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    private static let logTailLimit = 200

    private let store: FineTuneStore
    private let runner: FineTuneRunner
    private let fineTuneRoot: () -> URL?
    private let criteriaGenerator: FineTuneCriteriaGenerator
    /// Взаимный guard по mlx-памяти (задача 85): тюн/baseline и мини-чат не тянут
    /// mlx одновременно — старт любого из них гасит наш mlx-сервер первым.
    private let stopMlxServer: () -> Void

    private var runGen = 0
    private var environmentGen = 0
    private var datasetsGen = 0
    private var examplesGen = 0
    private var validateGen = 0
    private var baselineGen = 0
    private var snapshotGen = 0
    private var criteriaGen = 0
    private var criteriaGenerateGen = 0
    private var importGen = 0
    /// Текст исходного файла — не URL: файл выбирается через fileImporter и может
    /// уехать/стать недоступным к моменту нажатия «Импортировать».
    private var importSourceText: String?
    private var tailTimer: Timer?
    private var tail: FineTuneLogTail?
    /// Кольцевой буфер отображаемого хвоста лога — readNew() отдаёт только НОВЫЙ
    /// кусок, без накопления панель схлопывалась бы до последней строки.
    private var logLines: [String] = []
    private var isTicking = false

    init(store: FineTuneStore, runner: FineTuneRunner, fineTuneRoot: @escaping () -> URL?,
        criteriaProviders: @escaping () -> [ResolvedChatProvider] = { [] },
        stopMlxServer: @escaping () -> Void = {}) {
        self.store = store
        self.runner = runner
        self.fineTuneRoot = fineTuneRoot
        self.criteriaGenerator = FineTuneCriteriaGenerator(providers: criteriaProviders)
        self.stopMlxServer = stopMlxServer
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
        // Сбой валидации относится к тому датасету, на котором её жали: без сброса
        // блок валидации нового датасета показал бы чужую ошибку и спрятал под ней
        // собственный сохранённый результат.
        validationErrorText = nil
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

    /// `--min-assistant` берётся из FineTuneStore (per-датасет настройка, задача 82);
    /// результат парсится FineTuneValidationParser и сохраняется в стор — виден без
    /// повторного запуска. status < 0 — сам процесс не удалось запустить/он завис
    /// (не «датасет невалиден»), это ошибка уровня приложения, а не результат проверки.
    func validate(dataset: FineTuneDataset) async {
        guard !isValidating else { return }
        validateGen += 1
        let gen = validateGen
        isValidating = true
        validationErrorText = nil

        let minAssistant = store.minAssistant(workdir: dataset.workdir,
                                              hasOwnSystemPrompt: dataset.systemPromptPath != nil)
        let result = await runner.validate(dataset: dataset, minAssistant: minAssistant,
                                           maxReuse: store.maxReuse(workdir: dataset.workdir),
                                           systemPromptPath: dataset.systemPromptPath)
        guard gen == validateGen else { return }
        isValidating = false

        guard result.status >= 0 else {
            validationErrorText = result.output
            return
        }
        let parsed = FineTuneValidationParser.parse(status: result.status, stdout: result.stdout, stderr: result.stderr)
        store.setValidation(FineTuneValidationRecord(result: parsed), workdir: dataset.workdir)
    }

    /// Каталога baseline/ нет (например, tuned/ у диктовки) → nil, не ошибка —
    /// экран показывает подсказку, а не пустой список.
    func loadBaseline(dataset: FineTuneDataset) async {
        baselineGen += 1
        let gen = baselineGen
        guard let baselineURL = dataset.baselineURL else {
            baselineSnapshot = nil
            return
        }
        let snapshot = await Task.detached { FineTuneOutputsIO.readSnapshot(directory: baselineURL) }.value
        guard gen == baselineGen else { return }
        baselineSnapshot = snapshot
    }

    /// Запускает `baseline.py` на этом датасете (задача 83). mlx не тянет тюн и baseline
    /// одновременно — guard симметричен тому, что стоит в `FineTuneRunner.start()`.
    func snapshotBaseline(dataset: FineTuneDataset) async {
        guard !isSnapshottingBaseline else { return }
        guard !store.runs.contains(where: { $0.status == .running }) else {
            baselineErrorText = "Идёт обучение — mlx не потянет два процесса, дождитесь или остановите тюн."
            return
        }
        stopMlxServer()
        snapshotGen += 1
        let gen = snapshotGen
        isSnapshottingBaseline = true
        baselineErrorText = nil

        let requested = store.baselineCountOverrides[dataset.workdir] ?? 10
        let count = min(max(requested, 1), max(dataset.validCount, 1))
        let result = await runner.snapshotBaseline(dataset: dataset, count: count)
        guard gen == snapshotGen else { return }
        isSnapshottingBaseline = false

        guard result.status == 0 else {
            baselineErrorText = result.stderr.isEmpty ? result.output : result.stderr
            return
        }
        // Сначала refreshDatasets: при ПЕРВОМ снятии переданный dataset ещё со старым
        // baselineURL == nil, и loadBaseline по нему тихо сбросил бы снапшот в nil.
        await refreshDatasets()
        let fresh = datasets.first { $0.id == dataset.id } ?? dataset
        await loadBaseline(dataset: fresh)
    }

    /// Поколение сдвигается ДО остановки процесса — ответ ещё идущего `runner.snapshotBaseline`
    /// придёт позже и не должен перезаписать `isSnapshottingBaseline`/`baselineErrorText`,
    /// выставленные здесь явно.
    func cancelBaselineSnapshot(dataset: FineTuneDataset) async {
        guard isSnapshottingBaseline else { return }
        snapshotGen += 1
        isSnapshottingBaseline = false
        baselineErrorText = "Снятие baseline отменено."
        await runner.cancelBaseline(workdir: dataset.workdir)
    }

    /// criteria.md может весить десятки килобайт — читается один раз при выборе датасета.
    func loadCriteria(dataset: FineTuneDataset) async {
        criteriaGen += 1
        let gen = criteriaGen
        guard let criteriaURL = dataset.criteriaURL else {
            criteriaText = nil
            return
        }
        let text = await Task.detached { try? String(contentsOf: criteriaURL, encoding: .utf8) }.value
        guard gen == criteriaGen else { return }
        criteriaText = text
    }

    /// Генерирует criteria.md через LLM на примерах train-сплита (задача 83, вкладка
    /// «Обзор»/«Критерии») и перезаписывает файл в rootURL датасета — не vault.
    func generateCriteria(dataset: FineTuneDataset) async {
        guard !isGeneratingCriteria else { return }
        criteriaGenerateGen += 1
        let gen = criteriaGenerateGen
        isGeneratingCriteria = true
        criteriaGenErrorText = nil

        let trainURL = dataset.dataURL.appendingPathComponent("train.jsonl")
        let metaURL = dataset.dataURL.appendingPathComponent("train.meta.jsonl")
        let hasMeta = FileManager.default.fileExists(atPath: metaURL.path)
        let examples = await Task.detached {
            FineTuneDatasetScanner.examples(dataURL: trainURL, metaURL: hasMeta ? metaURL : nil)
        }.value
        guard gen == criteriaGenerateGen else { return }
        guard !examples.isEmpty else {
            isGeneratingCriteria = false
            criteriaGenErrorText = "В датасете нет примеров — нечего анализировать."
            return
        }

        do {
            let text = try await criteriaGenerator.generate(
                datasetTitle: dataset.title, system: examples.first?.system, examples: examples)
            guard gen == criteriaGenerateGen else { return }
            try await writeCriteria(text, dataset: dataset)
            guard gen == criteriaGenerateGen else { return }
            isGeneratingCriteria = false
            // Не loadCriteria(dataset:) — переданный dataset ещё не знает о только что
            // созданном файле (criteriaURL nil до пересканирования), текст уже в руках.
            criteriaText = text
            await refreshDatasets()
        } catch is CancellationError {
            guard gen == criteriaGenerateGen else { return }
            isGeneratingCriteria = false
        } catch {
            guard gen == criteriaGenerateGen else { return }
            isGeneratingCriteria = false
            criteriaGenErrorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Сохранение правок из редактора вкладки «Критерии» — тот же файл, что пишет генерация.
    @discardableResult
    func saveCriteria(dataset: FineTuneDataset, text: String) async -> Bool {
        do {
            try await writeCriteria(text, dataset: dataset)
        } catch {
            criteriaGenErrorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
        criteriaGenErrorText = nil
        criteriaText = text
        await refreshDatasets()
        return true
    }

    private func writeCriteria(_ text: String, dataset: FineTuneDataset) async throws {
        let criteriaURL = dataset.rootURL.appendingPathComponent("criteria.md")
        try await Task.detached { try Data(text.utf8).write(to: criteriaURL, options: .atomic) }.value
    }

    /// Читает файл под security scope (fileImporter отдаёт URL вне песочницы) и
    /// разбирает его чистым ядром в фоне; текст сохраняется для последующего импорта.
    func loadImportPreview(url: URL) async {
        importGen += 1
        let gen = importGen
        importErrorText = nil

        do {
            let (text, result) = try await Task.detached {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let text = try FineTuneDatasetImporter.readSource(url: url)
                return (text, FineTuneImportCore.parse(text: text))
            }.value
            guard gen == importGen else { return }
            importSourceText = text
            importPreview = result
        } catch {
            guard gen == importGen else { return }
            importSourceText = nil
            importPreview = nil
            importErrorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// По тексту, сохранённому `loadImportPreview` — не по URL. Успех переключает
    /// выбор на новый датасет и открывает «Обзор» (задача 83, целевой флоу импорта).
    func importDataset(name: String) async -> Bool {
        guard let sourceText = importSourceText else {
            importErrorText = "Файл не выбран."
            return false
        }
        guard let root = fineTuneRoot() else {
            importErrorText = FineTuneError.noRepoRoot.errorDescription
            return false
        }
        importGen += 1
        let gen = importGen
        isImporting = true
        importErrorText = nil
        let seed = UInt64.random(in: 1...UInt64(UInt32.max))
        do {
            let id = try await Task.detached {
                try FineTuneDatasetImporter.importDataset(from: sourceText, name: name, into: root, seed: seed)
            }.value
            guard gen == importGen else { return false }
            isImporting = false
            await refreshDatasets()
            store.selection = .dataset(id)
            store.datasetTab = .overview
            return true
        } catch {
            guard gen == importGen else { return false }
            isImporting = false
            importErrorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Сброс состояния sheet при закрытии — следующее открытие не должно показывать
    /// превью/ошибку прошлой попытки.
    func resetImport() {
        importGen += 1
        importPreview = nil
        importErrorText = nil
        importSourceText = nil
        isImporting = false
    }

    func start(dataset: FineTuneDataset, model: String, hyperparameters: FineTuneHyperparameters) async {
        stopMlxServer()
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

    /// run.json этого датасета — читается заново при входе на вкладку/смене выбора
    /// (см. FineTuneRunViews), не по таймеру: дёшево, но незачем гонять на каждый тик.
    func refreshCurrentRun(dataset: FineTuneDataset) async {
        currentCLIRunDataset = dataset
        currentCLIRun = await runner.currentCLIRun(dataset: dataset)
    }

    /// «Взять лучший» уместен только прогону, чьи pid/startedAt совпадают с тем, что
    /// СЕЙЧАС лежит в run.json этого workdir — иначе `best --install` установил бы
    /// чекпоинт по val-кривой другого (перезаписавшего run.json) прогона.
    func isCurrentRun(_ run: FineTuneRun) -> Bool {
        guard currentCLIRunDataset?.workdir == run.workdir, let cliRun = currentCLIRun, let pid = run.pid
        else { return false }
        return Int(pid) == cliRun.pid
            && abs(cliRun.startedAt.timeIntervalSince1970 - run.startedAt.timeIntervalSince1970) < 1
    }

    /// Работает над ПОКАЗАННЫМ прогоном (параметр — тот, что выбран в UI), не над
    /// tailedRunID: иначе кнопка тихо no-op'ает на любом прогоне, кроме тайлящегося.
    /// Сверка с run.json — заново, на момент клика (кэш `currentCLIRun` мог устареть).
    func installBest(run: FineTuneRun) async {
        guard let dataset = currentCLIRunDataset, dataset.workdir == run.workdir else {
            errorText = "Не удалось проверить run.json — откройте вкладку заново."
            return
        }
        currentCLIRun = await runner.currentCLIRun(dataset: dataset)
        guard isCurrentRun(run) else {
            errorText = "Этот прогон больше не совпадает с run.json — запущен другой тюн этого датасета."
            return
        }
        // Лениентный декодер FineTuneCLIRun допускает пустой adapter_path — тогда
        // --adapter-dir "" указал бы на корень workdir, а не на каталог адаптеров.
        guard !run.adapterPath.isEmpty else {
            errorText = "У прогона нет пути адаптера (битый run.json) — «Взять лучший» невозможен."
            return
        }
        let result = await runner.installBest(workdir: run.workdir, adapterDir: run.adapterPath)
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
