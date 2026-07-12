// BackgroundProcessRegistry.swift — единый владелец фоновых процессов приложения.
//
// Инвариант №2 (ARCHITECTURE.md): каждый процесс, запущенный приложением
// (Ollama и будущие рантаймы), регистрируется здесь и гарантированно гасится
// в applicationWillTerminate. Гашение с эскалацией: SIGTERM всем → ждём до
// grace-периода → выжившим SIGKILL. Сигнал шлётся группе процесса (killpg),
// если ребёнок стал лидером своей группы, иначе самому процессу — Ollama на
// SIGTERM корректно гасит своих runner-детей, так что дерево не сиротеет.
//
// Foundation.Process не даёт установить process group при spawn (нет
// POSIX_SPAWN_SETPGROUP), поэтому killpg — оппортунистический: сработает,
// если группа своя, безопасно провалится (ESRCH) — иначе. Реестр работает
// с протоколом ManagedProcess — в тестах процессы мокируются.

import Foundation

/// Абстракция управляемого фонового процесса (реальная — Foundation.Process).
protocol ManagedProcess: AnyObject {
    var isRunning: Bool { get }
    /// Мягкое завершение: SIGTERM (группе, если возможно).
    func sendTerminationSignal()
    /// Жёсткое: SIGKILL — для выживших после grace-периода.
    func sendKillSignal()
}

extension Process: ManagedProcess {
    func sendTerminationSignal() {
        guard isRunning else { return }
        let pid = processIdentifier
        // killpg убьёт всё дерево, если ребёнок — лидер группы; иначе ESRCH →
        // штатный terminate() самому процессу.
        if pid > 0, killpg(pid, SIGTERM) == 0 { return }
        terminate()
    }

    func sendKillSignal() {
        let pid = processIdentifier
        guard pid > 0 else { return }
        if killpg(pid, SIGKILL) != 0 {
            kill(pid, SIGKILL)
        }
    }
}

/// Реестр фоновых процессов.
final class BackgroundProcessRegistry {
    static let shared = BackgroundProcessRegistry()

    /// Зарегистрированные процессы; доступ только через lock — terminateAll
    /// зовётся из applicationWillTerminate, register — из произвольных очередей.
    private var processes: [ManagedProcess] = []
    private let lock = NSLock()

    /// Продакшн использует ТОЛЬКО shared (иначе процесс переживёт выход
    /// приложения); отдельные экземпляры создают исключительно тесты.
    init() {}

    /// Регистрирует запущенный процесс. Каждый spawn в кодовой базе обязан
    /// сопровождаться этим вызовом — иначе процесс осиротеет при выходе.
    func register(_ process: ManagedProcess) {
        lock.lock()
        defer { lock.unlock() }
        processes.append(process)
    }

    /// Количество живых (isRunning) зарегистрированных процессов.
    var runningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return processes.filter { $0.isRunning }.count
    }

    /// Гасит все зарегистрированные процессы: SIGTERM → ожидание до
    /// gracePeriod → SIGKILL выжившим. Блокирует вызывающий поток (зовётся
    /// из applicationWillTerminate, где это допустимо и необходимо).
    /// Идемпотентен: повторный вызов на пустом реестре — no-op.
    func terminateAll(gracePeriod: TimeInterval = 3.0) {
        lock.lock()
        let toTerminate = processes
        processes.removeAll()
        lock.unlock()

        let alive = toTerminate.filter { $0.isRunning }
        guard !alive.isEmpty else { return }

        for process in alive { process.sendTerminationSignal() }

        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline, alive.contains(where: { $0.isRunning }) {
            Thread.sleep(forTimeInterval: 0.05)
        }

        for process in alive where process.isRunning {
            process.sendKillSignal()
        }
    }
}
