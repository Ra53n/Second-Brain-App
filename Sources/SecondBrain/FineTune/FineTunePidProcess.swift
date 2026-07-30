// FineTunePidProcess.swift — обёртка pid обучения под ManagedProcess.
//
// Обучение спавнит train.py detached (`Popen(start_new_session=True)`) — у нас
// есть только pid, не Process. Реестру (инвариант №2) отдаём эту обёртку вместо
// Process. Лидер сессии — killpg гасит и воркеров.

import Foundation

final class FineTunePidProcess: ManagedProcess {
    let pid: Int32
    private let lock = NSLock()
    private var detached = false

    /// pid ≤ 1 отвергается: `killpg(0, …)` бьёт по группе процессов самого
    /// приложения, `killpg(1, …)` — по launchd. Битый или недописанный run.json
    /// не должен превращать «Остановить» в самоубийство.
    init?(pid: Int32) {
        guard pid > 1 else { return nil }
        self.pid = pid
    }

    var isDetached: Bool {
        lock.lock(); defer { lock.unlock() }
        return detached
    }

    /// «Оставить работать» при выходе — прогон больше не наш, terminateAll его пропускает.
    func detachFromQuit() {
        lock.lock()
        detached = true
        lock.unlock()
    }

    var isRunning: Bool {
        !isDetached && kill(pid, 0) == 0
    }

    func sendTerminationSignal() {
        guard !isDetached else { return }
        killpg(pid, SIGTERM)
    }

    func sendKillSignal() {
        guard !isDetached else { return }
        killpg(pid, SIGKILL)
    }
}
