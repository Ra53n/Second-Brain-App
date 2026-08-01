// MlxServerManagerTests.swift — жизненный цикл mlx_lm.server (задача 85): регистрация в
// BackgroundProcessRegistry до health-check, рестарт при смене конфига (adapterPath),
// тот же конфиг — no-op, health не поднялся → failed + throw, порт занят чужим процессом —
// не адоптируем и не спавним поверх, idle гасит только собственный процесс.

import XCTest
@testable import SecondBrain

private final class MockManagedProcess: ManagedProcess {
    private(set) var termCount = 0
    private(set) var running = true
    var isRunning: Bool { running }
    func sendTerminationSignal() { termCount += 1; running = false }
    func sendKillSignal() { running = false }
}

/// Точка рандеву: `arrive()` не возвращается, пока не соберётся `expected` вызовов —
/// гарантированно сталкивает две конкурентные корутины в одной точке (не полагается на
/// то, что async-без-await-внутри исполнится синхронно и «повезёт» с чередованием).
private actor Rendezvous {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrived = 0
    private let expected: Int
    init(expected: Int) { self.expected = expected }

    func arrive() async {
        arrived += 1
        if arrived >= expected {
            let toResume = waiters
            waiters = []
            for continuation in toResume { continuation.resume() }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
final class MlxServerManagerTests: XCTestCase {

    private let fakePython = URL(fileURLWithPath: "/fake/python3")

    func testRegistersInRegistryBeforeHealthCheckSucceeds() async throws {
        var registeredBeforeReady = false
        var healthCallCount = 0
        let registry = BackgroundProcessRegistry()
        let process = MockManagedProcess()
        let manager = MlxServerManager(
            registry: registry,
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in process },
            health: { _ in
                healthCallCount += 1
                // Первый вызов — pre-check «порт занят?» ДО спавна (порт свободен).
                guard healthCallCount > 1 else { return false }
                registeredBeforeReady = registry.runningCount == 1
                return true
            },
            pythonResolver: { self.fakePython },
            healthRetryDelay: 0)

        try await manager.ensureRunning(MlxServerConfig())
        XCTAssertTrue(registeredBeforeReady, "процесс обязан быть в реестре до того, как health-check вернёт готовность")
        XCTAssertEqual(manager.status, .running(MlxServerConfig()))
    }

    func testSameConfigDoesNotRespawn() async throws {
        var spawnCount = 0
        var healthCallCount = 0
        let manager = MlxServerManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in spawnCount += 1; return MockManagedProcess() },
            health: { _ in
                healthCallCount += 1
                return healthCallCount > 1
            },
            pythonResolver: { self.fakePython },
            healthRetryDelay: 0)

        let config = MlxServerConfig()
        try await manager.ensureRunning(config)
        XCTAssertEqual(spawnCount, 1)
        try await manager.ensureRunning(config)
        XCTAssertEqual(spawnCount, 1, "тот же конфиг — no-op")
    }

    func testAdapterPathChangeRestartsServer() async throws {
        var spawnCount = 0
        var healthCallCount = 0
        var processes: [MockManagedProcess] = []
        let manager = MlxServerManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in
                spawnCount += 1
                let process = MockManagedProcess()
                processes.append(process)
                return process
            },
            // Нечётный вызов — pre-check перед очередным спавном (порт свободен),
            // чётный — readiness-проверка сразу после (сервер поднялся).
            health: { _ in
                healthCallCount += 1
                return healthCallCount % 2 == 0
            },
            pythonResolver: { self.fakePython },
            healthRetryDelay: 0)

        try await manager.ensureRunning(MlxServerConfig(adapterPath: nil))
        XCTAssertEqual(spawnCount, 1)

        try await manager.ensureRunning(MlxServerConfig(adapterPath: URL(fileURLWithPath: "/adapters")))
        XCTAssertEqual(spawnCount, 2, "смена adapterPath — рестарт")
        XCTAssertEqual(processes.first?.termCount, 1, "старый процесс погашен перед новым спавном")
    }

    func testHealthNeverRespondsSetsFailedAndThrows() async throws {
        let process = MockManagedProcess()
        let manager = MlxServerManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in process },
            health: { _ in false }, // порт свободен, но сервер так и не поднимается
            pythonResolver: { self.fakePython },
            healthRetryDelay: 0,
            healthTimeout: 0.05)

        do {
            try await manager.ensureRunning(MlxServerConfig())
            XCTFail("ожидалась ошибка")
        } catch let error as FineTuneError {
            guard case .mlxServerUnavailable = error else {
                XCTFail("ожидался .mlxServerUnavailable, получено \(error)")
                return
            }
        }
        XCTAssertEqual(process.termCount, 1, "не поднявшийся процесс гасится")
        guard case .failed = manager.status else {
            XCTFail("ожидался статус .failed, получено \(manager.status)")
            return
        }
    }

    func testForeignProcessOnPortIsNotAdoptedNorSpawnedOver() async throws {
        var spawnCount = 0
        let manager = MlxServerManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in spawnCount += 1; return MockManagedProcess() },
            health: { _ in true }, // порт уже отвечает — не наш процесс
            pythonResolver: { self.fakePython },
            healthRetryDelay: 0)

        do {
            try await manager.ensureRunning(MlxServerConfig())
            XCTFail("ожидалась ошибка «порт занят»")
        } catch let error as FineTuneError {
            guard case .mlxServerUnavailable = error else {
                XCTFail("ожидался .mlxServerUnavailable, получено \(error)")
                return
            }
        }
        XCTAssertEqual(spawnCount, 0, "чужой сервер не адоптируется и не спавнится поверх")
    }

    func testIdleShutdownStopsOnlyOwnProcess() async throws {
        var now: TimeInterval = 0
        var healthCallCount = 0
        let process = MockManagedProcess()
        let manager = MlxServerManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { now }),
            spawn: { _, _ in process },
            health: { _ in
                healthCallCount += 1
                return healthCallCount > 1
            },
            pythonResolver: { self.fakePython },
            healthRetryDelay: 0)

        try await manager.ensureRunning(MlxServerConfig())
        now = 100
        manager.shutdownIfIdle()
        XCTAssertEqual(process.termCount, 0, "окно простоя ещё не истекло")

        now = 700
        manager.shutdownIfIdle()
        XCTAssertEqual(process.termCount, 1, "простаивающий свой процесс гасится")
        XCTAssertEqual(manager.status, .stopped)
    }

    /// НАЙДЕННЫЙ ДЕФЕКТ (задача 85, не исправлен — вне полномочий tester, чинит coder):
    /// два `ensureRunning` того же конфига запущены конкурентно, оба зависают на
    /// `pythonResolver` до тех пор, пока не соберутся вместе (`Rendezvous`) — это
    /// заставляет обоих пройти ранний guard `if let startupTask` ДО того, как первый
    /// вызов вообще успевает его выставить (`MlxServerManager.swift:79` — guard проверяется
    /// один раз при входе, не перепроверяется после await-разрывов `pythonResolver`/`health`).
    /// Итог — оба спавнят `mlx_lm.server`, второй никогда не гасится: два процесса висят
    /// на одном порту. Тест ниже фиксирует ОЖИДАЕМОЕ поведение (spawnCount == 1) и сейчас
    /// падает, потому что фактическое spawnCount == 2 — см. `## Отчёт тестов`.
    func testConcurrentEnsureRunningRacesIntoDoubleSpawn() async throws {
        let rendezvous = Rendezvous(expected: 2)
        var spawnCount = 0
        let manager = MlxServerManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in spawnCount += 1; return MockManagedProcess() },
            health: { _ in false },
            pythonResolver: {
                await rendezvous.arrive()
                return self.fakePython
            },
            healthRetryDelay: 0,
            healthTimeout: 0.05)

        let config = MlxServerConfig()
        async let first: () = manager.ensureRunning(config)
        async let second: () = manager.ensureRunning(config)
        _ = try? await (first, second)

        XCTAssertEqual(spawnCount, 1, "конкурентный старт того же конфига обязан спавнить ровно один процесс")
    }

    /// `stopNow()` во время `.starting` (сервер ещё грузится) обязан оставить `.stopped`,
    /// а не дать фоновому старту молча перезаписать статус обратно на `.running` —
    /// иначе кнопка «Остановить» в UI, нажатая во время загрузки модели, ничего не значит.
    func testStopNowDuringStartingKeepsStoppedStatus() async throws {
        let startedLoading = Rendezvous(expected: 2)
        let manager = MlxServerManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in MockManagedProcess() },
            health: { _ in
                await startedLoading.arrive()
                return false // никогда не готов — статус застревает в .starting до таймаута
            },
            pythonResolver: { self.fakePython },
            healthRetryDelay: 0.01,
            healthTimeout: 0.1)

        let config = MlxServerConfig()
        let task = Task { try? await manager.ensureRunning(config) }
        await startedLoading.arrive() // дождались, что стартовый Task дошёл до health-поллинга
        manager.stopNow()
        XCTAssertEqual(manager.status, .stopped, "stopNow во время старта обязан оставить .stopped")
        _ = await task.result // дать заброшенному старту доиграть healthTimeout, не оставлять висящий Task
    }

    /// Генерация (`serverGen`, P5): `stopNow()` во время `.starting` гасит процесс и
    /// фиксирует `.stopped`; health, ответивший успехом ПОЗЖЕ (уже после stopNow), не
    /// должен «воскресить» процесс — устаревшее поколение гасит свежеспавненный
    /// процесс и выходит, не трогая status/spawnedProcess.
    func testLateHealthAfterStopNowDoesNotResurrectServer() async throws {
        let reachedReadinessPoll = Rendezvous(expected: 2)
        var callCount = 0
        var respondHealthy = false
        let process = MockManagedProcess()
        let manager = MlxServerManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in process },
            health: { _ in
                callCount += 1
                if callCount == 1 { return false } // pre-check: порт свободен
                if callCount == 2 { await reachedReadinessPoll.arrive() } // первый опрос ВНУТРИ waitHealthy
                return respondHealthy
            },
            pythonResolver: { self.fakePython },
            healthRetryDelay: 0.01,
            healthTimeout: 1)

        let config = MlxServerConfig()
        let task = Task { try? await manager.ensureRunning(config) }
        await reachedReadinessPoll.arrive()
        manager.stopNow()
        XCTAssertEqual(manager.status, .stopped)
        XCTAssertEqual(process.termCount, 1, "stopNow гасит уже спавненный процесс")

        respondHealthy = true // «поздний» успех — уже после stopNow
        _ = await task.result
        XCTAssertEqual(manager.status, .stopped, "поздний health не должен воскрешать процесс")
    }
}
