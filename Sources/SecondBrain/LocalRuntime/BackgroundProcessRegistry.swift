// BackgroundProcessRegistry.swift — единый владелец фоновых процессов приложения.
//
// Инвариант №2 (ARCHITECTURE.md): каждый процесс, запущенный приложением
// (Ollama и будущие рантаймы), регистрируется здесь и гарантированно гасится
// в applicationWillTerminate. Хук обязан существовать с первого дня (задача 01),
// чтобы ни один более поздний модуль не запустил процесс мимо реестра.
//
// TODO(задача 09): ленивый запуск Ollama, idle-таймаут, отдельная process
// group против осиротевших процессов — портировать RagOllamaLauncher из MA.

import Foundation

/// Реестр фоновых процессов. Пока умеет только регистрировать и гасить —
/// логика запуска появится в задаче 09 (менеджер локальных LLM).
final class BackgroundProcessRegistry {
    static let shared = BackgroundProcessRegistry()

    /// Зарегистрированные процессы; доступ только через lock — terminateAll
    /// зовётся из applicationWillTerminate, register — из произвольных очередей.
    private var processes: [Process] = []
    private let lock = NSLock()

    /// init приватный: единственный экземпляр — shared, иначе процесс можно
    /// зарегистрировать в «чужом» реестре и он переживёт выход приложения.
    private init() {}

    /// Регистрирует запущенный процесс. Каждый spawn в кодовой базе обязан
    /// сопровождаться этим вызовом — иначе процесс осиротеет при выходе.
    func register(_ process: Process) {
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

    /// Гасит все зарегистрированные процессы. Идемпотентен: повторный вызов
    /// на пустом/погашенном реестре — no-op. Зовётся из applicationWillTerminate.
    func terminateAll() {
        lock.lock()
        let toTerminate = processes
        processes.removeAll()
        lock.unlock()

        for process in toTerminate where process.isRunning {
            process.terminate()
        }
    }
}
