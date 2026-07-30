// FineTuneQuitGuard.swift — мост между разделом «Тюнинг» и AppDelegate на выходе
// приложения: AppDelegate не знает о FineTuneRunner/FineTuneStore напрямую.

import Foundation

enum FineTuneQuitGuard {
    /// Живой прогон на момент запроса выхода: что показать в диалоге и что сделать
    /// по каждой из двух кнопок действия.
    struct Active {
        let datasetTitle: String
        let progress: String
        let stop: () -> Void
        let detach: () -> Void
    }

    /// nil — живого прогона нет, AppDelegate завершает выход без диалога.
    static var probe: (() -> Active?)?

    /// Прогон для диалога выхода: чужой (`isAdoptedExternally`) сюда не попадает —
    /// инвариант №2 запрещает гасить процесс, который приложение не запускало, а выход
    /// из приложения гасит автоматически. Ручное «Остановить» на чужом прогоне остаётся
    /// доступным в разделе: это явное решение пользователя, а не побочный эффект Cmd+Q.
    static func activeRun(in runs: [FineTuneRun]) -> FineTuneRun? {
        runs.first { $0.status == .running && !$0.isAdoptedExternally }
    }

    /// Ждёт async-операцию не дольше `timeout`: `applicationShouldTerminate` не должен
    /// висеть на CLI (до 30 с) или резолве python (кэш пуст — до 30 с на кандидата).
    /// Не уложились — операция доработает в фоне, а выход продолжится, и дальше решает
    /// `terminateAll()`: для «Остановить» это тот же исход, для «Оставить работать» —
    /// противоположный обещанному (прогон всё-таки погаснет). Риск мал: `detach` —
    /// синхронная простановка флагов без единого `await` внутри, в таймаут не упирается.
    static func waitFor(timeout: TimeInterval = 5, _ operation: @escaping () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { // не наследует MainActor вызывающего — иначе wait() дедлокнулся бы о себя
            await operation()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }
}
