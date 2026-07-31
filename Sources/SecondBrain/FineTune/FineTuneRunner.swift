// FineTuneRunner.swift — раннер CLI-тюнинга (P4, инвариант №2).
//
// `train.py start` спавнит обучение через Popen(start_new_session=True) и сразу
// выходит — процесс нам не ребёнок, есть только pid из runs/run.json. Раннер
// зовёт `start`/`stop`/`best --install` подкомандами и читает run.json/train.log,
// в Swift argv для mlx_lm.lora не собирает. `runCLI` инжектируется ради тестов
// без реального Process (образец чтения вывода — RunCommandTool: terminationHandler
// ставится ДО run(), читатель в отдельной задаче — иначе deadlock на заполненном pipe).

import Foundation

actor FineTuneRunner {
    struct CLIResult: Equatable {
        let status: Int32
        let output: String
        /// Раздельные stdout/stderr — нужны FineTuneValidationParser (заметки в stdout,
        /// ошибки в stderr); train.py-команды пишут оба в один pipe и оставляют их пустыми.
        let stdout: String
        let stderr: String

        init(status: Int32, output: String, stdout: String = "", stderr: String = "") {
            self.status = status
            self.output = output
            self.stdout = stdout
            self.stderr = stderr
        }
    }
    typealias CLIRunner = (_ workdir: String, _ arguments: [String]) async -> CLIResult
    typealias ValidateCLIRunner = (_ arguments: [String]) async -> CLIResult

    /// Команды CLI без явного проброса Process — щедрее обычной (`train.py start`
    /// делает до двух пробных `--help` с импортом mlx, см. lora_command в train.py).
    private static let defaultCLITimeoutSeconds: TimeInterval = 30
    private static let startCLITimeoutSeconds: TimeInterval = 180
    /// validate.py — секунды, чистый stdlib: таймаут короче обычного CLI.
    private static let validateCLITimeoutSeconds: TimeInterval = 15
    /// baseline.py генерирует ответы локальной моделью — минуты, иногда десятки минут.
    private static let baselineCLITimeoutSeconds: TimeInterval = 1800

    /// Снимок корня finetune/ (не замыкание на MainActor-состояние — см. частые
    /// ошибки в FineTune/CLAUDE.md): обновляется извне через `updateRoot(_:)`.
    private var fineTuneRoot: URL?
    private let injectedRunCLI: CLIRunner?
    private let injectedValidateCLI: ValidateCLIRunner?
    private let injectedBaselineCLI: ValidateCLIRunner?
    private let registry: BackgroundProcessRegistry
    /// Проба python дорогая (десятки секунд) — кэш живёт, пока жив раннер.
    private var cachedPython: URL?
    private var liveProcesses: [String: FineTunePidProcess] = [:]
    /// Хэндлы идущего снятия baseline, ключ — workdir датасета (задача 83): нужны
    /// для `cancelBaseline`, снимаются сами по завершении `defaultRunBaseline`.
    private var baselineProcesses: [String: Process] = [:]
    /// Workdir'ы с идущим снятием baseline — источник guard'а в `start()`. Заполняется
    /// в `snapshotBaseline` целиком (не только в `defaultRunBaseline`), иначе
    /// инжектированный тестовый CLI не мог бы смоделировать «занято» без реального Process.
    private var baselineWorkdirs: Set<String> = []

    init(fineTuneRoot: URL?, runCLI: CLIRunner? = nil, validateCLI: ValidateCLIRunner? = nil,
         baselineCLI: ValidateCLIRunner? = nil, registry: BackgroundProcessRegistry = .shared) {
        self.fineTuneRoot = fineTuneRoot
        self.injectedRunCLI = runCLI
        self.injectedValidateCLI = validateCLI
        self.injectedBaselineCLI = baselineCLI
        self.registry = registry
    }

    /// Смена репозитория проекта (AppModel.wire): старый venv/python больше не в счёт.
    func updateRoot(_ root: URL?) {
        fineTuneRoot = root
        cachedPython = nil
    }

    /// Живой pid уже идёт — throw .alreadyRunning без обращения к CLI.
    func start(dataset: FineTuneDataset, model: String,
               hyperparameters: FineTuneHyperparameters) async throws -> FineTuneRun {
        // mlx не тянет тюн и снятие baseline одновременно (задача 83) — guard
        // симметричен тому, что `snapshotBaseline` не запустится при идущем тюне
        // (проверяется выше, в FineTuneViewModel, по store.runs).
        guard baselineWorkdirs.isEmpty else {
            throw FineTuneError.baselineRunning
        }
        if let cliRun = await adopt(dataset: dataset) {
            throw FineTuneError.alreadyRunning(pid: Int32(cliRun.pid))
        }

        let arguments = ["--model", model, "start"] + hyperparameters.cliArguments()
        let result = await runCLI(workdir: dataset.workdir, arguments: arguments)
        guard result.status == 0 else {
            throw FineTuneError.startFailed(result.output)
        }
        guard let cliRun = readRunJSON(dataset: dataset) else {
            throw FineTuneError.startFailed("run.json не найден после старта")
        }

        let pid = Int32(clamping: cliRun.pid)
        guard let process = FineTunePidProcess(pid: pid) else {
            throw FineTuneError.startFailed("run.json вернул недопустимый pid \(cliRun.pid)")
        }
        registry.register(process)
        liveProcesses[dataset.workdir] = process

        var run = FineTuneRun(workdir: dataset.workdir, datasetTitle: dataset.title, model: model,
                              hyperparameters: hyperparameters, logPath: cliRun.log,
                              adapterPath: cliRun.adapterPath)
        run.pid = pid
        run.startedAt = cliRun.startedAt
        return run
    }

    @discardableResult
    func stop(workdir: String) async -> CLIResult {
        let result = await runCLI(workdir: workdir, arguments: ["stop"])
        // train.py stop возвращает 0 только когда pid подтверждённо мёртв (см. cmd_stop) —
        // при неуспехе процесс мог остаться жить, тогда отслеживание не снимаем.
        if result.status == 0 {
            retireLiveProcess(workdir: workdir)
        }
        return result
    }

    /// Читает run.json и проверяет живость pid — без него не определить, идёт ли обучение,
    /// начатое до перезапуска приложения (или запущенное вручную из терминала).
    func adopt(dataset: FineTuneDataset) async -> FineTuneCLIRun? {
        guard let cliRun = readRunJSON(dataset: dataset), cliRun.pid > 1,
              kill(pid_t(clamping: cliRun.pid), 0) == 0 else { return nil }
        return cliRun
    }

    /// Регистрирует уже идущий (подхваченный) прогон в реестре процессов — вызывающий
    /// (FineTuneViewModel) обязан подтвердить ПЕРЕД вызовом, что workdir+pid совпадают
    /// с записью в FineTuneStore, оставленной нашим же прошлым `start()`. Прогон,
    /// запущенный вне приложения, сюда не попадает — «чужой процесс не гасится
    /// никогда» (инвариант №2).
    @discardableResult
    func adoptIntoRegistry(workdir: String, pid: Int32) -> Bool {
        guard liveProcesses[workdir] == nil, let process = FineTunePidProcess(pid: pid) else { return false }
        registry.register(process)
        liveProcesses[workdir] = process
        return true
    }

    /// Процесс обнаружен мёртвым извне (ViewModel.tick по факту kill(pid,0)!=0) —
    /// снимаем с отслеживания и переводим в detached: иначе переиспользование этого
    /// pid системой позже подставило бы terminateAll() под чужой процесс.
    func markProcessFinished(workdir: String) {
        retireLiveProcess(workdir: workdir)
    }

    func installBest(workdir: String) async -> CLIResult {
        await runCLI(workdir: workdir, arguments: ["best", "--install"])
    }

    /// `validate.py <data>/train.jsonl <data>/valid.jsonl [--system …] [--min-assistant N]`,
    /// рабочий каталог — сам finetune/ (не dataset.workdir, у validate.py нет `--workdir`).
    func validate(dataset: FineTuneDataset, minAssistant: Int?, systemPromptPath: String?) async -> CLIResult {
        guard let root = fineTuneRoot else {
            return CLIResult(status: -1, output: "Каталог finetune/ не найден.")
        }
        var arguments = [
            dataset.dataURL.appendingPathComponent("train.jsonl").path,
            dataset.dataURL.appendingPathComponent("valid.jsonl").path
        ]
        if let systemPromptPath { arguments += ["--system", systemPromptPath] }
        if let minAssistant { arguments += ["--min-assistant", String(minAssistant)] }

        if let injectedValidateCLI { return await injectedValidateCLI(arguments) }
        return await defaultRunValidate(root: root, arguments: arguments)
    }

    /// `baseline.py --data <dataset>/data --out <dataset>/baseline --count N`, рабочий
    /// каталог — сам finetune/ (как validate.py); python — тот же простой выбор, что
    /// и у validate (первый исполняемый кандидат, без пробы импорта mlx-lm).
    func snapshotBaseline(dataset: FineTuneDataset, count: Int) async -> CLIResult {
        guard let root = fineTuneRoot else {
            return CLIResult(status: -1, output: "Каталог finetune/ не найден.")
        }
        // Без этого guard'а второй вызов на том же workdir (например, сразу после
        // cancelBaseline — процесс живёт ещё до ~3 с) стартовал бы второй baseline.py
        // параллельно, а defer'ы ПЕРВОГО прогона стёрли бы хэндлы ВТОРОГО (задача 83, ревью).
        guard !baselineWorkdirs.contains(dataset.workdir) else {
            return CLIResult(status: -1, output: "Предыдущее снятие baseline ещё завершается — подождите пару секунд.")
        }
        let outURL = dataset.rootURL.appendingPathComponent("baseline")
        let arguments = ["--data", dataset.dataURL.path, "--out", outURL.path, "--count", String(count)]

        baselineWorkdirs.insert(dataset.workdir)
        defer { baselineWorkdirs.remove(dataset.workdir) }

        if let injectedBaselineCLI { return await injectedBaselineCLI(arguments) }
        return await defaultRunBaseline(root: root, arguments: arguments, workdir: dataset.workdir)
    }

    /// Мягкая остановка идущего снятия baseline (SIGTERM, затем SIGKILL выжившему через
    /// 3 с — как реестр гасит процессы на выходе). Хэндл снимается сам в
    /// `defaultRunBaseline` по завершении, здесь только сигнал.
    func cancelBaseline(workdir: String) {
        guard let process = baselineProcesses[workdir] else { return }
        process.sendTerminationSignal()
        Task.detached { [process] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if process.isRunning { process.sendKillSignal() }
        }
    }

    /// «Оставить работать» при выходе приложения — прогоны больше не наши, terminateAll их пропускает.
    func detachAllFromQuit() {
        for process in liveProcesses.values { process.detachFromQuit() }
    }

    private func retireLiveProcess(workdir: String) {
        liveProcesses[workdir]?.detachFromQuit()
        liveProcesses[workdir] = nil
    }

    // MARK: - CLI

    private func runCLI(workdir: String, arguments: [String]) async -> CLIResult {
        if let injectedRunCLI { return await injectedRunCLI(workdir, arguments) }
        return await defaultRunCLI(workdir: workdir, arguments: arguments)
    }

    private func defaultRunCLI(workdir: String, arguments: [String]) async -> CLIResult {
        guard let root = fineTuneRoot else {
            return CLIResult(status: -1, output: "Каталог finetune/ не найден.")
        }
        let trainPy = root.appendingPathComponent("train.py")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = MCPEnv.augmentedPATH(extra: environment["PATH"] ?? "")
        let python = await resolvePython(root: root, environment: environment)

        let process = Process()
        process.currentDirectoryURL = root
        process.environment = environment
        if let python {
            process.executableURL = python
            process.arguments = [trainPy.path, "--workdir", workdir] + arguments
        } else {
            // Ни один известный python не нашёлся — пробуем системный через env,
            // train.py сам импортирует только stdlib и локальный mlxenv.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", trainPy.path, "--workdir", workdir] + arguments
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let terminated = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield(())
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch {
            return CLIResult(status: -1, output: "не удалось запустить train.py: \(error.localizedDescription)")
        }

        let handle = pipe.fileHandleForReading
        let reader = Task.detached(priority: .utility) { (try? handle.readToEnd()) ?? Data() }
        // Зависший интерпретатор не должен подвешивать «Запустить тюн»/выход приложения
        // навсегда — SIGTERM, затем SIGKILL выжившему (образец — RunCommandTool).
        let timeout = arguments.contains("start") ? Self.startCLITimeoutSeconds : Self.defaultCLITimeoutSeconds
        let watchdog = Task.detached { [timeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            guard !Task.isCancelled, process.isRunning else { return false }
            process.sendTerminationSignal()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if process.isRunning { process.sendKillSignal() }
            return true
        }

        for await _ in terminated { break }
        watchdog.cancel()
        let timedOut = await watchdog.value
        let data = await reader.value
        let output = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if timedOut {
            let tail = output.isEmpty ? "" : "\nВывод до остановки:\n\(output)"
            return CLIResult(status: -1,
                             output: "train.py \(arguments.joined(separator: " ")) не завершился за \(Int(timeout)) с и был остановлен.\(tail)")
        }
        return CLIResult(status: process.terminationStatus, output: output)
    }

    /// validate.py — чистый stdlib, mlx-lm ему не нужен: не пробуем импорт (дорого и
    /// не по делу), берём первый исполняемый кандидат из того же списка, что и train.py.
    private func defaultRunValidate(root: URL, arguments: [String]) async -> CLIResult {
        let validatePy = root.appendingPathComponent("validate.py")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = MCPEnv.augmentedPATH(extra: environment["PATH"] ?? "")
        guard let python = FineTuneEnvironment.candidates(fineTuneRoot: root, environment: environment)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else {
            return CLIResult(status: -1, output: FineTuneEnvironment.installHint)
        }

        let process = Process()
        process.currentDirectoryURL = root
        process.environment = environment
        process.executableURL = python
        process.arguments = [validatePy.path] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let terminated = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield(())
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            return CLIResult(status: -1, output: "не удалось запустить validate.py: \(error.localizedDescription)")
        }
        // После run(), а не до: у реестра нет снятия с регистрации, и незапущенный
        // Process остался бы в нём навсегда — по записи на каждый клик кнопки.
        registry.register(process)

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutReader = Task.detached(priority: .utility) { (try? stdoutHandle.readToEnd()) ?? Data() }
        let stderrReader = Task.detached(priority: .utility) { (try? stderrHandle.readToEnd()) ?? Data() }
        let watchdog = Task.detached { [timeout = Self.validateCLITimeoutSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            guard !Task.isCancelled, process.isRunning else { return false }
            process.sendTerminationSignal()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if process.isRunning { process.sendKillSignal() }
            return true
        }

        for await _ in terminated { break }
        watchdog.cancel()
        let timedOut = await watchdog.value
        let stdoutData = await stdoutReader.value
        let stderrData = await stderrReader.value
        let stdout = String(data: stdoutData, encoding: .utf8) ?? String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(data: stderrData, encoding: .utf8) ?? String(decoding: stderrData, as: UTF8.self)

        if timedOut {
            return CLIResult(status: -1,
                             output: "validate.py не завершился за \(Int(Self.validateCLITimeoutSeconds)) с и был остановлен.",
                             stdout: stdout, stderr: stderr)
        }
        return CLIResult(status: process.terminationStatus, output: stdout + stderr, stdout: stdout, stderr: stderr)
    }

    /// Как `defaultRunValidate`, но: другой скрипт, свой таймаут-вотчдог и хэндл в
    /// `baselineProcesses` (снимается через `defer`, доступен `cancelBaseline` всё
    /// время прогона — иначе кнопка «Отменить» не нашла бы, что останавливать).
    private func defaultRunBaseline(root: URL, arguments: [String], workdir: String) async -> CLIResult {
        let baselinePy = root.appendingPathComponent("baseline.py")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = MCPEnv.augmentedPATH(extra: environment["PATH"] ?? "")
        guard let python = FineTuneEnvironment.candidates(fineTuneRoot: root, environment: environment)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else {
            return CLIResult(status: -1, output: FineTuneEnvironment.installHint)
        }

        let process = Process()
        process.currentDirectoryURL = root
        process.environment = environment
        process.executableURL = python
        process.arguments = [baselinePy.path] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let terminated = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield(())
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            return CLIResult(status: -1, output: "не удалось запустить baseline.py: \(error.localizedDescription)")
        }
        // После run(), а не до — см. defaultRunValidate; тот же резон для baselineProcesses.
        registry.register(process)
        baselineProcesses[workdir] = process
        // Идентичность, не просто ключ — entry-guard в snapshotBaseline уже не даёт двум
        // прогонам на одном workdir идти параллельно, но это последний рубеж на случай
        // будущего рефакторинга guard'а.
        defer { if baselineProcesses[workdir] === process { baselineProcesses[workdir] = nil } }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutReader = Task.detached(priority: .utility) { (try? stdoutHandle.readToEnd()) ?? Data() }
        let stderrReader = Task.detached(priority: .utility) { (try? stderrHandle.readToEnd()) ?? Data() }
        let watchdog = Task.detached { [timeout = Self.baselineCLITimeoutSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            guard !Task.isCancelled, process.isRunning else { return false }
            process.sendTerminationSignal()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if process.isRunning { process.sendKillSignal() }
            return true
        }

        for await _ in terminated { break }
        watchdog.cancel()
        let timedOut = await watchdog.value
        let stdoutData = await stdoutReader.value
        let stderrData = await stderrReader.value
        let stdout = String(data: stdoutData, encoding: .utf8) ?? String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(data: stderrData, encoding: .utf8) ?? String(decoding: stderrData, as: UTF8.self)

        if timedOut {
            return CLIResult(status: -1,
                             output: "baseline.py не завершился за \(Int(Self.baselineCLITimeoutSeconds)) с и был остановлен.",
                             stdout: stdout, stderr: stderr)
        }
        return CLIResult(status: process.terminationStatus, output: stdout + stderr, stdout: stdout, stderr: stderr)
    }

    private func resolvePython(root: URL, environment: [String: String]) async -> URL? {
        if let cachedPython { return cachedPython }
        for candidate in FineTuneEnvironment.candidates(fineTuneRoot: root, environment: environment) {
            let ok = await Task.detached { FineTuneEnvironment.probe(candidate) }.value
            if ok {
                cachedPython = candidate
                return candidate
            }
        }
        return nil
    }

    private func readRunJSON(dataset: FineTuneDataset) -> FineTuneCLIRun? {
        let url = dataset.rootURL.appendingPathComponent("runs/run.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FineTuneCLIRun.self, from: data)
    }
}
