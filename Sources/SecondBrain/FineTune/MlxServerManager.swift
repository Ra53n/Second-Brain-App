// MlxServerManager.swift — жизненный цикл `mlx_lm.server` для мини-чата тюнинга
// (задача 85, инвариант №2, образец — LocalRuntime/OllamaManager).
//
// В отличие от Ollama чужой сервер на порту НЕ адоптируется — вариант модели
// снаружи неизвестен, подключение к нему выдало бы ответы неизвестно какой
// модели за baseline/тюн. Порт занят не нами → ошибка, не автоподключение.
// Проба python кэшируется на уровне менеджера (не в каждом ensureRunning) —
// проба `import mlx_lm.server` дорогая, как и в FineTuneEnvironment.probe.

import Combine
import Foundation

struct MlxServerConfig: Equatable {
    static let defaultModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    static let defaultPort = 18765

    var model: String
    var adapterPath: URL?
    var port: Int

    init(model: String = MlxServerConfig.defaultModel, adapterPath: URL? = nil,
         port: Int = MlxServerConfig.defaultPort) {
        self.model = model
        self.adapterPath = adapterPath
        self.port = port
    }
}

@MainActor
final class MlxServerManager: ObservableObject {

    enum Status: Equatable {
        case stopped
        case starting(String)
        case running(MlxServerConfig)
        case failed(String)
    }

    @Published private(set) var status: Status = .stopped

    private let registry: BackgroundProcessRegistry
    private let idlePolicy: IdleShutdownPolicy
    private let spawn: (URL, MlxServerConfig) throws -> ManagedProcess
    private let health: (Int) async -> Bool
    private let pythonResolver: () async -> URL?
    private let healthRetryDelay: TimeInterval
    private let healthTimeout: TimeInterval

    private var spawnedProcess: ManagedProcess?
    private var runningConfig: MlxServerConfig?
    private var cachedPython: URL?
    private var idleTimer: Timer?
    /// Второй ensureRunning того же конфига ждёт первый, не плодит второй spawn —
    /// startupTask/startupConfig выставляются АТОМАРНО (без await между проверкой
    /// и записью), см. ensureRunning.
    private var startupTask: Task<Void, Error>?
    private var startupConfig: MlxServerConfig?
    /// Поколение старта: bump — только в `stopNow()`. Сверка после каждого await
    /// в ensureRunning/finishStartup (P5) — устаревшее поколение гасит то, что успело
    /// спавниться, и выходит без записи статуса (stopNow уже записал своё).
    private var serverGen = 0

    init(registry: BackgroundProcessRegistry = .shared,
         idlePolicy: IdleShutdownPolicy = IdleShutdownPolicy(),
         spawn: @escaping (URL, MlxServerConfig) throws -> ManagedProcess = MlxServerManager.defaultSpawn,
         health: @escaping (Int) async -> Bool = MlxServerManager.isServerResponding,
         pythonResolver: @escaping () async -> URL? = MlxServerManager.defaultPythonResolver,
         healthRetryDelay: TimeInterval = 1.0,
         healthTimeout: TimeInterval = 120) {
        self.registry = registry
        self.idlePolicy = idlePolicy
        self.spawn = spawn
        self.health = health
        self.pythonResolver = pythonResolver
        self.healthRetryDelay = healthRetryDelay
        self.healthTimeout = healthTimeout
        startIdleTimer()
    }

    // MARK: - Жизненный цикл

    /// Гарантирует сервер с данным конфигом: тот же конфиг уже работает → no-op;
    /// другой — гасим свой и поднимаем заново (смена baseline↔тюн — рестарт).
    ///
    /// Конкурентные вызовы того же конфига: guard `alreadyHandling` перепроверяется
    /// ПОСЛЕ КАЖДОГО await (P5) — конкурент, обогнавший нас, пока мы резолвили python
    /// или проверяли занятость порта, обнаруживается сразу, и мы просто ждём ЕГО task,
    /// не спавним второй раз. Финальный отрезок «проверка → spawn → регистрация →
    /// startupTask=…» — без единого await между ними, поэтому ровно один из
    /// конкурентов физически успевает его пройти (MainActor не прерывает синхронный
    /// код между await-точками) — это и есть точка, где решается «кто спавнит».
    func ensureRunning(_ config: MlxServerConfig) async throws {
        markUsed()
        if let task = alreadyHandling(config) {
            try await task.value
            return
        }
        if case .running(let current) = status, current == config {
            markUsed()
            return
        }
        if let startupTask {
            // Стартует ДРУГОЙ конфиг прямо сейчас — дождаться исхода и решить заново.
            _ = try? await startupTask.value
            try await ensureRunning(config)
            return
        }
        if case .running = status {
            stopNow()
        }

        let startGen = serverGen
        status = .starting("Запуск mlx-сервера…")

        if cachedPython == nil {
            cachedPython = await pythonResolver()
        }
        guard startGen == serverGen else { return } // stopNow() отменил, пока резолвили python
        if let task = alreadyHandling(config) { try await task.value; return }
        guard let python = cachedPython else {
            guard startGen == serverGen else { return }
            let message = FineTuneEnvironment.installHint
            status = .failed(message)
            throw FineTuneError.mlxServerUnavailable(message)
        }

        // Порт уже отвечает, а наш процесс не запущен — чужой сервер: не
        // адоптируем (вариант модели неизвестен) и не гасим.
        guard !(await health(config.port)) else {
            guard startGen == serverGen else { return }
            if let task = alreadyHandling(config) { try await task.value; return }
            let message = "Порт \(config.port) занят посторонним процессом — mlx-сервер не запущен."
            status = .failed(message)
            throw FineTuneError.mlxServerUnavailable(message)
        }
        guard startGen == serverGen else { return } // stopNow() отменил, пока проверяли порт
        if let task = alreadyHandling(config) { try await task.value; return }

        // Атомарный участок: ни одного await между финальной проверкой и спавном.
        let process: ManagedProcess
        do {
            process = try spawn(python, config)
        } catch {
            guard startGen == serverGen else { return }
            status = .failed(error.localizedDescription)
            throw FineTuneError.mlxServerUnavailable(error.localizedDescription)
        }
        registry.register(process)
        guard startGen == serverGen else {
            // stopNow() сработал прямо во время спавна — гасим свежий процесс, не публикуем его.
            process.sendTerminationSignal()
            return
        }
        spawnedProcess = process
        status = .starting("Загрузка модели…")

        let task = Task<Void, Error> { [self] in
            try await finishStartup(process: process, config: config, gen: startGen)
        }
        startupTask = task
        startupConfig = config
        // Безопасно чистить безусловно: пока наш task не завершён, никто другой не
        // может подменить startupTask — конкурент того же конфига ждёт ЕГО (не создаёт
        // свой), конкурент другого конфига сперва ждёт завершения нашего.
        defer { startupTask = nil; startupConfig = nil }
        try await task.value
    }

    /// Health-поллинг после спавна → публикация `.running`/`.failed`. Сверка `gen ==
    /// serverGen` (P5) ПОСЛЕ waitHealthy — если stopNow() сработал, пока ждали
    /// готовности, свежеспавненный процесс гасится сам, статус не перезаписывается
    /// (иначе поздний успешный health «воскресил» бы уже остановленный сервер).
    private func finishStartup(process: ManagedProcess, config: MlxServerConfig, gen: Int) async throws {
        guard await waitHealthy(port: config.port) else {
            guard gen == serverGen else { return }
            process.sendTerminationSignal()
            if spawnedProcess === process { spawnedProcess = nil }
            let message = "mlx-сервер не ответил за \(Int(healthTimeout)) с"
            status = .failed(message)
            throw FineTuneError.mlxServerUnavailable(message)
        }
        guard gen == serverGen else {
            process.sendTerminationSignal()
            if spawnedProcess === process { spawnedProcess = nil }
            return
        }
        runningConfig = config
        status = .running(config)
        markUsed()
    }

    /// Существующий startupTask того же конфига — вызывающему остаётся его дождаться,
    /// а не спавнить второй сервер. Синхронно (без await): только это делает проверку
    /// в ensureRunning надёжной точкой синхронизации между конкурентами.
    private func alreadyHandling(_ config: MlxServerConfig) -> Task<Void, Error>? {
        guard let startupTask, startupConfig == config else { return nil }
        return startupTask
    }

    func markUsed() { idlePolicy.markUsed() }

    /// Гасит ТОЛЬКО наш процесс; статус просто «остановлен», если процесса нет
    /// (уже погашен либо не поднимался). Поколение всегда сдвигается — даже во
    /// время старта (до спавна) это гарантирует, что `ensureRunning` не спавнит
    /// сервер уже ПОСЛЕ отмены, а фоновый startupTask отменяется явно.
    func stopNow() {
        serverGen += 1
        startupTask?.cancel()
        guard let process = spawnedProcess else {
            status = .stopped
            runningConfig = nil
            return
        }
        process.sendTerminationSignal()
        spawnedProcess = nil
        runningConfig = nil
        status = .stopped
    }

    /// Проверка idle-таймера: гасим только простаивающий наш процесс.
    func shutdownIfIdle() {
        guard spawnedProcess != nil, idlePolicy.shouldShutdown else { return }
        stopNow()
    }

    func setIdleTimeout(_ seconds: TimeInterval) { idlePolicy.timeout = seconds }

    // MARK: - Дефолтные зависимости

    nonisolated static func defaultSpawn(python: URL, config: MlxServerConfig) throws -> ManagedProcess {
        let process = Process()
        process.executableURL = python
        var arguments = ["-m", "mlx_lm.server", "--model", config.model]
        if let adapterPath = config.adapterPath {
            arguments += ["--adapter-path", adapterPath.path]
        }
        arguments += ["--host", "127.0.0.1", "--port", String(config.port)]
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    nonisolated static func isServerResponding(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// Дефолтный резолвер python: кандидаты `FineTuneEnvironment` + проба
    /// `import mlx_lm.server` (шире, чем проба `mlx_lm` из train.py). Реальный
    /// корень finetune/ приложение знает только в AppModel — там резолвер
    /// подменяется на использующий актуальный `fineTuneRoot`.
    nonisolated static func defaultPythonResolver() async -> URL? {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = MCPEnv.augmentedPATH(extra: environment["PATH"] ?? "")
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("finetune")
        let candidates = FineTuneEnvironment.candidates(fineTuneRoot: root, environment: environment)
        return await Task.detached { candidates.first { probeServerModule($0) } }.value
    }

    nonisolated static func probeServerModule(
        _ python: URL, timeoutSeconds: TimeInterval = FineTuneEnvironment.defaultProbeTimeoutSeconds
    ) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import mlx_lm.server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        guard semaphore.wait(timeout: .now() + timeoutSeconds) != .timedOut else {
            process.sendTerminationSignal()
            _ = semaphore.wait(timeout: .now() + 2)
            if process.isRunning { process.sendKillSignal() }
            return false
        }
        return process.terminationStatus == 0
    }

    // MARK: - Внутренности

    /// Модель грузится минуты — ждём до healthTimeout, опрашивая с паузой healthRetryDelay.
    private func waitHealthy(port: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(healthTimeout)
        while Date() < deadline, !Task.isCancelled {
            if await health(port) { return true }
            if healthRetryDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(healthRetryDelay * 1_000_000_000))
            }
        }
        return await health(port)
    }

    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.shutdownIfIdle() }
        }
    }
}
