// OllamaManager.swift — жизненный цикл локального Ollama (порт+расширение
// RagOllamaLauncher из MA).
//
// Принципы (инвариант №2 ARCHITECTURE.md):
//  - ленивый старт: сервер поднимается при первом обращении к локальной модели;
//  - чужой сервер не трогаем: если Ollama уже отвечает (официальный Ollama.app,
//    ручной запуск) — подключаемся и НЕ гасим его ни по idle, ни при выходе;
//  - наш спавн регистрируется в BackgroundProcessRegistry (гарантированное
//    гашение в applicationWillTerminate) и гасится по idle-таймауту
//    (IdleShutdownPolicy, дефолт 10 мин с последнего запроса);
//  - если бинарь не найден — понятная ошибка с путём установки (ollama.com,
//    brew), не молчаливый фейл.
//
// Зависимости (спавн, health-check, поиск бинаря, часы) инжектируются —
// логика менеджера тестируется без реального Ollama.

import Combine
import Foundation

/// Ошибки локального рантайма; сообщения пригодны для UI.
enum OllamaError: LocalizedError, Equatable {
    case notInstalled
    case startFailed(String)
    case badURL
    case badStatus(code: Int, message: String)
    case pullFailed(String)
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Ollama не установлен. Скачайте с ollama.com или выполните «brew install ollama»."
        case let .startFailed(detail):
            return "Не удалось запустить Ollama: \(detail)"
        case .badURL:
            return "Некорректный адрес локального сервера."
        case let .badStatus(code, message):
            return "Ollama HTTP \(code): \(message)"
        case let .pullFailed(text):
            return "Не удалось скачать модель: \(text)"
        case let .modelNotFound(name):
            return "Модель «\(name)» не найдена."
        }
    }
}

/// Политика idle-гашения: чистая, часы инжектируются (тестируемость).
final class IdleShutdownPolicy {
    /// Настраивается пользователем (задача 17) через set*IdleTimeout владельца.
    var timeout: TimeInterval
    private let clock: () -> TimeInterval
    private var lastUsed: TimeInterval

    init(timeout: TimeInterval = 600,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.timeout = timeout
        self.clock = clock
        self.lastUsed = clock()
    }

    /// Отметка «рантайм только что использовали» — сдвигает окно простоя.
    func markUsed() { lastUsed = clock() }

    /// Пора ли гасить: с последнего использования прошло ≥ timeout.
    var shouldShutdown: Bool { clock() - lastUsed >= timeout }
}

@MainActor
final class OllamaManager: ObservableObject {

    enum RuntimeStatus: Equatable {
        case stopped          // не запущен (или не установлен)
        case starting         // спавним и ждём health-check
        case runningSpawned   // работает, запустили МЫ (гасим по idle/выходу)
        case runningExternal  // работает чужой (не трогаем никогда)

        var label: String {
            switch self {
            case .stopped: return "Остановлен"
            case .starting: return "Запускается…"
            case .runningSpawned: return "Работает (запущен приложением)"
            case .runningExternal: return "Работает (внешний — не трогаем)"
            }
        }
    }

    @Published private(set) var status: RuntimeStatus = .stopped

    let baseURL: String

    // Инжектируемые зависимости (тесты подменяют).
    private let spawn: (URL, String) throws -> ManagedProcess
    private let health: (String) async -> Bool
    private let binaryLocator: () -> URL?
    private let registry: BackgroundProcessRegistry
    private let idlePolicy: IdleShutdownPolicy
    /// Пауза между попытками health-check (в тестах — 0).
    private let healthRetryDelay: TimeInterval

    private var spawnedProcess: ManagedProcess?
    private var idleTimer: Timer?
    /// Защита от параллельных стартов: второй ensureRunning ждёт первого.
    private var startupTask: Task<Void, Error>?

    init(baseURL: String = "http://127.0.0.1:11434",
         registry: BackgroundProcessRegistry = .shared,
         idlePolicy: IdleShutdownPolicy = IdleShutdownPolicy(),
         spawn: @escaping (URL, String) throws -> ManagedProcess = OllamaManager.defaultSpawn,
         health: @escaping (String) async -> Bool = OllamaManager.isServerResponding,
         binaryLocator: @escaping () -> URL? = OllamaManager.findBinary,
         healthRetryDelay: TimeInterval = 0.5) {
        self.baseURL = baseURL
        self.registry = registry
        self.idlePolicy = idlePolicy
        self.spawn = spawn
        self.health = health
        self.binaryLocator = binaryLocator
        self.healthRetryDelay = healthRetryDelay
        startIdleTimer()
    }

    /// Установлен ли Ollama (для isAvailable в реестре провайдеров и UI).
    var isInstalled: Bool { binaryLocator() != nil }

    // MARK: - Жизненный цикл

    /// Гарантирует работающий сервер: уже отвечает → подключаемся (external);
    /// иначе ленивый спавн нашего с ожиданием health-check.
    func ensureRunning() async throws {
        markUsed()
        // Кто-то уже стартует — ждём его результата, не плодим дубль.
        if let startupTask {
            try await startupTask.value
            return
        }
        if await health(baseURL) {
            if status != .runningSpawned { status = .runningExternal }
            return
        }
        guard let binary = binaryLocator() else {
            status = .stopped
            throw OllamaError.notInstalled
        }

        let task = Task<Void, Error> { [self] in
            status = .starting
            let process: ManagedProcess
            do {
                process = try spawn(binary, Self.hostPort(baseURL))
            } catch {
                status = .stopped
                throw OllamaError.startFailed(error.localizedDescription)
            }
            registry.register(process)
            spawnedProcess = process
            guard await waitHealthy() else {
                stopNow()
                throw OllamaError.startFailed("сервер не ответил после запуска")
            }
            status = .runningSpawned
            markUsed()
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    /// Отметка использования (каждый запрос к серверу) — сдвигает idle-окно.
    func markUsed() { idlePolicy.markUsed() }

    /// Новый idle-таймаут из настроек (задача 17); действует со следующей
    /// проверки таймера.
    func setIdleTimeout(_ seconds: TimeInterval) { idlePolicy.timeout = seconds }

    /// Гасит сервер, ТОЛЬКО если запускали мы. Чужой (external) не трогаем —
    /// кнопка «Остановить сейчас» и idle-таймер оба идут сюда.
    func stopNow() {
        guard let process = spawnedProcess else {
            // Чужой сервер: наш статус просто «не подключены».
            if status == .runningExternal { status = .stopped }
            return
        }
        process.sendTerminationSignal()
        spawnedProcess = nil
        status = .stopped
    }

    /// Проверка idle-таймера: гасим ТОЛЬКО собственный простаивающий процесс.
    func shutdownIfIdle() {
        guard spawnedProcess != nil, idlePolicy.shouldShutdown else { return }
        stopNow()
    }

    /// Актуализация статуса для UI (например, чужой сервер погас сам).
    func refreshStatus() async {
        let responding = await health(baseURL)
        switch (responding, spawnedProcess) {
        case (true, .some): status = .runningSpawned
        case (true, .none): status = .runningExternal
        case (false, _):
            if status != .starting { status = .stopped }
        }
    }

    // MARK: - Дефолтные зависимости

    /// Спавн ollama serve: вывод в null-девайсы, OLLAMA_HOST из baseURL.
    nonisolated static func defaultSpawn(binary: URL, hostPort: String) throws -> ManagedProcess {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = hostPort
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Health-check: GET /api/version с коротким таймаутом.
    nonisolated static func isServerResponding(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL + "/api/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// Поиск бинаря: PATH + типовые места установки (официальный Ollama.app,
    /// Homebrew оба варианта, /usr/local).
    nonisolated static func findBinary() -> URL? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("ollama")
            }
        }
        candidates += [
            URL(fileURLWithPath: "/Applications/Ollama.app/Contents/Resources/ollama"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ollama"),
            URL(fileURLWithPath: "/usr/local/bin/ollama"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// «host:port» из baseURL для OLLAMA_HOST (дефолт 127.0.0.1:11434).
    nonisolated static func hostPort(_ baseURL: String) -> String {
        guard let url = URL(string: baseURL) else { return "127.0.0.1:11434" }
        return "\(url.host ?? "127.0.0.1"):\(url.port ?? 11434)"
    }

    // MARK: - Внутренности

    /// Ждёт готовности сервера (до ~15 с; serve биндит порт за 1–2 с).
    private func waitHealthy() async -> Bool {
        for _ in 0..<30 {
            if await health(baseURL) { return true }
            if healthRetryDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(healthRetryDelay * 1_000_000_000))
            }
        }
        return await health(baseURL)
    }

    /// Периодическая проверка простоя (каждые 30 с). Timer держит слабую
    /// ссылку — деинициализация менеджера его отпускает.
    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.shutdownIfIdle() }
        }
    }
}
