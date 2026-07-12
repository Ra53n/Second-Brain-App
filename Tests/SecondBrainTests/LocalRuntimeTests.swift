// LocalRuntimeTests.swift — задача 09: реестр фоновых процессов (эскалация
// TERM → KILL на моках), idle-политика с инжектируемыми часами, жизненный
// цикл OllamaManager (ленивый старт, «не гасить чужой сервер», not-installed),
// DTO/парсеры Ollama API по фикстурам.

import XCTest
@testable import SecondBrain

// MARK: - Мок процесса

private final class MockProcess: ManagedProcess {
    private(set) var termCount = 0
    private(set) var killCount = 0
    /// Умирает ли процесс от SIGTERM (false — «завис», нужна эскалация).
    var diesOnTerm = true
    private(set) var running = true

    var isRunning: Bool { running }

    func sendTerminationSignal() {
        termCount += 1
        if diesOnTerm { running = false }
    }

    func sendKillSignal() {
        killCount += 1
        running = false
    }
}

// MARK: - Реестр процессов

final class BackgroundProcessRegistryTests: XCTestCase {

    func testTerminateAllSendsTermToAllRunning() {
        let registry = BackgroundProcessRegistry()
        let a = MockProcess(), b = MockProcess()
        registry.register(a)
        registry.register(b)
        XCTAssertEqual(registry.runningCount, 2)

        registry.terminateAll(gracePeriod: 0.2)
        XCTAssertEqual(a.termCount, 1)
        XCTAssertEqual(b.termCount, 1)
        XCTAssertEqual(a.killCount, 0, "послушный процесс не получает SIGKILL")
        XCTAssertEqual(registry.runningCount, 0)
    }

    func testTerminateAllEscalatesToKillForSurvivors() {
        let registry = BackgroundProcessRegistry()
        let stubborn = MockProcess()
        stubborn.diesOnTerm = false // игнорирует SIGTERM
        registry.register(stubborn)

        registry.terminateAll(gracePeriod: 0.15)
        XCTAssertEqual(stubborn.termCount, 1)
        XCTAssertEqual(stubborn.killCount, 1, "выживший после grace-периода получает SIGKILL")
        XCTAssertFalse(stubborn.isRunning)
    }

    func testTerminateAllIsIdempotent() {
        let registry = BackgroundProcessRegistry()
        let process = MockProcess()
        registry.register(process)
        registry.terminateAll(gracePeriod: 0.1)
        registry.terminateAll(gracePeriod: 0.1) // второй вызов — no-op
        XCTAssertEqual(process.termCount, 1)
    }

    func testDeadProcessesAreNotSignalled() {
        let registry = BackgroundProcessRegistry()
        let dead = MockProcess()
        dead.sendKillSignal() // уже мёртв
        registry.register(dead)
        registry.terminateAll(gracePeriod: 0.1)
        XCTAssertEqual(dead.termCount, 0)
    }

    /// Контракт applicationWillTerminate (из задачи 01): пустой реестр — no-op.
    func testTerminateAllIsIdempotentOnEmptyRegistry() {
        let registry = BackgroundProcessRegistry.shared
        registry.terminateAll()
        registry.terminateAll()
        XCTAssertEqual(registry.runningCount, 0)
    }

    /// Незапущенный Process регистрируется, но не «живой» — terminateAll
    /// его не трогает (terminate() по не-running процессу падает).
    func testRegisterNotRunningProcess() {
        let registry = BackgroundProcessRegistry()
        registry.register(Process())
        XCTAssertEqual(registry.runningCount, 0)
        registry.terminateAll(gracePeriod: 0.1)
        XCTAssertEqual(registry.runningCount, 0)
    }
}

// MARK: - Idle-политика

final class IdleShutdownPolicyTests: XCTestCase {

    func testShutdownAfterTimeout() {
        var now: TimeInterval = 1000
        let policy = IdleShutdownPolicy(timeout: 600, clock: { now })
        XCTAssertFalse(policy.shouldShutdown)
        now = 1599
        XCTAssertFalse(policy.shouldShutdown, "599 c — ещё рано")
        now = 1600
        XCTAssertTrue(policy.shouldShutdown, "ровно 600 c — пора")
    }

    func testMarkUsedResetsWindow() {
        var now: TimeInterval = 0
        let policy = IdleShutdownPolicy(timeout: 600, clock: { now })
        now = 500
        policy.markUsed() // активность в середине окна
        now = 1000
        XCTAssertFalse(policy.shouldShutdown, "окно отсчитывается от markUsed")
        now = 1100
        XCTAssertTrue(policy.shouldShutdown)
    }
}

// MARK: - OllamaManager (моки спавна/health/детекта)

@MainActor
final class OllamaManagerTests: XCTestCase {

    /// Менеджер с полностью замоканными зависимостями.
    private func makeManager(healthy: @escaping () -> Bool,
                             binary: URL? = URL(fileURLWithPath: "/fake/ollama"),
                             idleTimeout: TimeInterval = 600,
                             clock: @escaping () -> TimeInterval = { 0 },
                             spawned: MockProcess = MockProcess(),
                             registry: BackgroundProcessRegistry = BackgroundProcessRegistry())
    -> (OllamaManager, MockProcess, BackgroundProcessRegistry) {
        let manager = OllamaManager(
            registry: registry,
            idlePolicy: IdleShutdownPolicy(timeout: idleTimeout, clock: clock),
            spawn: { _, _ in spawned },
            health: { _ in healthy() },
            binaryLocator: { binary },
            healthRetryDelay: 0)
        return (manager, spawned, registry)
    }

    func testExternalServerIsUsedAndNeverStopped() async throws {
        // Сервер уже отвечает (запущен пользователем) — подключаемся, не спавним.
        let (manager, process, _) = makeManager(healthy: { true })
        try await manager.ensureRunning()
        XCTAssertEqual(manager.status, .runningExternal)
        XCTAssertEqual(process.termCount, 0)

        // Ни ручной стоп, ни idle не трогают чужой сервер.
        manager.stopNow()
        manager.shutdownIfIdle()
        XCTAssertEqual(process.termCount, 0, "чужой Ollama не трогаем никогда")
        XCTAssertEqual(process.killCount, 0)
    }

    func testLazySpawnWhenServerNotResponding() async throws {
        // Health false до спавна, true после (сервер поднялся).
        var spawnedFlag = false
        let (manager, process, registry) = makeManager(healthy: { spawnedFlag })
        let realSpawn = process
        let managerWithSpawnFlag = OllamaManager(
            registry: registry,
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in spawnedFlag = true; return realSpawn },
            health: { _ in spawnedFlag },
            binaryLocator: { URL(fileURLWithPath: "/fake/ollama") },
            healthRetryDelay: 0)
        _ = manager
        try await managerWithSpawnFlag.ensureRunning()
        XCTAssertEqual(managerWithSpawnFlag.status, .runningSpawned)
        XCTAssertEqual(registry.runningCount, 1, "спавн зарегистрирован в реестре")
    }

    func testNotInstalledThrowsClearError() async {
        let (manager, _, _) = makeManager(healthy: { false }, binary: nil)
        do {
            try await manager.ensureRunning()
            XCTFail("ожидалась OllamaError.notInstalled")
        } catch {
            XCTAssertEqual(error as? OllamaError, .notInstalled)
        }
        XCTAssertEqual(manager.status, .stopped)
    }

    func testIdleShutdownStopsOnlyOwnSpawn() async throws {
        var now: TimeInterval = 0
        var serverUp = false
        let process = MockProcess()
        let manager = OllamaManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { now }),
            spawn: { _, _ in serverUp = true; return process },
            health: { _ in serverUp },
            binaryLocator: { URL(fileURLWithPath: "/fake/ollama") },
            healthRetryDelay: 0)

        try await manager.ensureRunning()
        XCTAssertEqual(manager.status, .runningSpawned)

        now = 100
        manager.shutdownIfIdle()
        XCTAssertEqual(process.termCount, 0, "окно простоя ещё не истекло")

        now = 700 // 600 c от markUsed на старте
        manager.shutdownIfIdle()
        XCTAssertEqual(process.termCount, 1, "простаивающий СВОЙ процесс гасится")
        XCTAssertEqual(manager.status, .stopped)
    }

    func testStopNowTerminatesOwnSpawn() async throws {
        var serverUp = false
        let process = MockProcess()
        let manager = OllamaManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in serverUp = true; return process },
            health: { _ in serverUp },
            binaryLocator: { URL(fileURLWithPath: "/fake/ollama") },
            healthRetryDelay: 0)
        try await manager.ensureRunning()
        manager.stopNow()
        XCTAssertEqual(process.termCount, 1)
        XCTAssertEqual(manager.status, .stopped)
    }

    func testHostPortParsing() {
        XCTAssertEqual(OllamaManager.hostPort("http://127.0.0.1:11434"), "127.0.0.1:11434")
        XCTAssertEqual(OllamaManager.hostPort("http://localhost:9999"), "localhost:9999")
        XCTAssertEqual(OllamaManager.hostPort("мусор"), "127.0.0.1:11434")
    }
}

// MARK: - DTO / парсеры по фикстурам

final class OllamaParsingTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json",
                                    subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    func testParseTagsFixture() throws {
        let models = try OllamaParsing.parseTags(fixture("ollama_tags"))
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].name, "qwen3:8b")
        XCTAssertEqual(models[0].sizeBytes, 5_026_369_536)
        XCTAssertEqual(models[0].quantization, "Q4_K_M")
        XCTAssertEqual(models[0].parameterSize, "8.2B")
        XCTAssertNotNil(models[0].detailLine)
        XCTAssertEqual(models[1].name, "nomic-embed-text:latest")
    }

    func testParseTagsEmptyAndGarbage() throws {
        XCTAssertEqual(try OllamaParsing.parseTags(Data("{}".utf8)), [])
        XCTAssertThrowsError(try OllamaParsing.parseTags(Data("не json".utf8)))
    }

    func testParseChatFixture() throws {
        let result = try OllamaParsing.parseChatResponse(fixture("ollama_chat"))
        XCTAssertEqual(result.text, "Привет! Чем помочь?")
        XCTAssertEqual(result.usage, ChatUsage(promptTokens: 26,
                                               completionTokens: 298,
                                               totalTokens: 324))
    }

    func testParseChatEmptyMessageThrows() {
        let json = #"{"message":{"role":"assistant","content":""},"done":true}"#
        XCTAssertThrowsError(try OllamaParsing.parseChatResponse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? LLMError, .emptyResponse)
        }
    }

    func testParseEmbedFixture() throws {
        let vectors = try OllamaParsing.parseEmbedResponse(fixture("ollama_embed"))
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0].count, 4)
        XCTAssertEqual(vectors[0][0], 0.010071029, accuracy: 1e-6)
    }

    func testParsePullLineProgress() {
        let line = #"{"status":"downloading sha256:abc","total":5026369536,"completed":2513184768}"#
        let progress = OllamaParsing.parsePullLine(line)
        XCTAssertEqual(progress?.status, "downloading sha256:abc")
        XCTAssertEqual(progress?.fraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertFalse(progress?.isSuccess ?? true)
    }

    func testParsePullLineStages() {
        // Этап без размера → fraction nil.
        let manifest = OllamaParsing.parsePullLine(#"{"status":"pulling manifest"}"#)
        XCTAssertNil(manifest?.fraction)
        // Успех.
        let success = OllamaParsing.parsePullLine(#"{"status":"success"}"#)
        XCTAssertTrue(success?.isSuccess ?? false)
        // Ошибка сервера в стриме.
        let failed = OllamaParsing.parsePullLine(#"{"error":"pull model manifest: file does not exist"}"#)
        XCTAssertEqual(failed?.errorText, "pull model manifest: file does not exist")
        // Мусор и пустые строки.
        XCTAssertNil(OllamaParsing.parsePullLine(""))
        XCTAssertNil(OllamaParsing.parsePullLine("не json"))
        XCTAssertNil(OllamaParsing.parsePullLine("{}"))
    }

    func testParseChatStreamLines() {
        let delta = OllamaParsing.parseChatStreamLine(
            #"{"message":{"role":"assistant","content":"При"},"done":false}"#)
        XCTAssertEqual(delta?.delta, "При")
        XCTAssertEqual(delta?.done, false)
        let final = OllamaParsing.parseChatStreamLine(
            #"{"message":{"content":""},"done":true,"eval_count":10}"#)
        XCTAssertEqual(final?.done, true)
        XCTAssertNil(OllamaParsing.parseChatStreamLine("мусор"))
    }
}
