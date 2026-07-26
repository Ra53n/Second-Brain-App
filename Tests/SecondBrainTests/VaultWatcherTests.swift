// VaultWatcherTests.swift — интеграционные тесты FSEvents-наблюдателя.
//
// Покрытие:
//  - VaultWatcher: одиночное изменение долетает как onChange;
//  - дымовая проверка коалесценции burst-записей (не строгая проверка
//    Debouncer.schedule() — её ловит DebouncerTests);
//  - stop() безопасен при повторном вызове и отменяет ещё не сработавший
//    запланированный onChange.

import XCTest
import Foundation
@testable import SecondBrain

final class VaultWatcherTests: VaultTestCase {

    /// Одиночная правка файла → onChange вызывается.
    func testSingleFileChangeTriggersCallback() throws {
        let file = try makeFile("test.md", contents: "версия 1")

        var eventCount = 0
        let expectation = self.expectation(description: "onChange вызван")

        let watcher = VaultWatcher(url: tempDir, debounce: 0.2) {
            eventCount += 1
            expectation.fulfill()
        }
        defer { watcher.stop() }

        // Внешняя правка файла
        try "версия 2".write(to: file, atomically: true, encoding: .utf8)

        wait(for: [expectation], timeout: 5.0)
        XCTAssertGreaterThan(eventCount, 0, "onChange должен вызваться как минимум один раз")
    }

    /// Создание нового файла → onChange вызывается.
    func testNewFileCreationTriggersCallback() throws {
        var eventCount = 0
        let expectation = self.expectation(description: "onChange вызван для создания")

        let watcher = VaultWatcher(url: tempDir, debounce: 0.2) {
            eventCount += 1
            expectation.fulfill()
        }
        defer { watcher.stop() }

        // Создание файла после старта watcher
        try makeFile("new.md", contents: "содержимое")

        wait(for: [expectation], timeout: 5.0)
        XCTAssertGreaterThan(eventCount, 0)
    }

    /// Дымовая проверка: пачка быстрых write не плодит явно избыточные дубли onChange.
    /// НЕ строгая проверка дебаунс-логики — системная задержка FSEvents (0.3 с,
    /// зашита в VaultWatcher, не зависит от параметра `debounce`) сама коалесцирует
    /// такой burst до раздачи нашему `Debouncer`; на практике наблюдается 1 событие
    /// (проверено 8 прогонами подряд). Регрессию именно `Debouncer.schedule()` ловит
    /// `DebouncerTests` в VaultTests.swift.
    func testRapidChangesAreDebouncedReasonably() throws {
        let file = try makeFile("test.md", contents: "v1")

        var eventCount = 0
        let countLock = NSLock()
        let firstEvent = self.expectation(description: "хотя бы одно событие")

        let watcher = VaultWatcher(url: tempDir, debounce: 0.15) {
            countLock.lock()
            defer { countLock.unlock() }
            eventCount += 1
            if eventCount == 1 {
                firstEvent.fulfill()
            }
        }
        defer { watcher.stop() }

        // Пачка быстрых изменений
        for i in 1...5 {
            try "v\(i+1)".write(to: file, atomically: true, encoding: .utf8)
            usleep(50000) // 50 мс между изменениями
        }

        wait(for: [firstEvent], timeout: 5.0)

        // После первого события ждём 1 с (достаточно, чтобы дебаунс завершился)
        let finalWait = self.expectation(description: "пауза после событий")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            finalWait.fulfill()
        }
        wait(for: [finalWait], timeout: 2.0)

        // Граница ≤2, а не ≤5: на практике из-за системной коалесценции FSEvents
        // такой burst всегда даёт 1 событие — 3+ означало бы явную регрессию.
        XCTAssertLessThanOrEqual(eventCount, 2,
            "Быстрые изменения не должны плодить явные дубли: получили \(eventCount) вызовов")
    }

    /// stop() идемпотентен (безопасен при повторном вызове) и вызванный до того, как
    /// FSEvents-задержка + debounce успели бы доставить событие, гарантированно
    /// подавляет последующий onChange — не только уже запланированный debounce-таймер,
    /// но и сам FSEventStream.
    func testStopIsIdempotent() throws {
        let file = try makeFile("test.md", contents: "v1")
        var eventCount = 0

        let watcher = VaultWatcher(url: tempDir, debounce: 0.3) {
            eventCount += 1
        }

        // Триггерим изменение и почти сразу останавливаем — раньше, чем истечёт и
        // системная задержка FSEvents (0.3 с), и наш debounce (0.3 с), так что
        // запланированный вызов onChange не должен успеть сработать.
        try "v2".write(to: file, atomically: true, encoding: .utf8)
        usleep(50000) // 50 мс

        watcher.stop()
        watcher.stop() // Дважды — должна быть idempotent
        watcher.stop() // Трижды — не крашит и не паникует

        // Ждём дольше суммарной задержки (FSEvents + debounce), чтобы поймать
        // отложенное срабатывание, если stop() его не отменил
        let waited = self.expectation(description: "пауза после stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            waited.fulfill()
        }
        wait(for: [waited], timeout: 2.0)

        XCTAssertEqual(eventCount, 0, "после stop() запланированный onChange не должен сработать")
    }

    /// Создание файла в подпапке → onChange вызывается (рекурсивное наблюдение).
    func testNestedFileChangeTriggersCallback() throws {
        try makeDir("subdir")
        let file = try makeFile("subdir/nested.md", contents: "v1")

        var eventCount = 0
        let expectation = self.expectation(description: "onChange для вложенного файла")

        let watcher = VaultWatcher(url: tempDir, debounce: 0.2) {
            eventCount += 1
            expectation.fulfill()
        }
        defer { watcher.stop() }

        // Правка вложенного файла
        try "v2".write(to: file, atomically: true, encoding: .utf8)

        wait(for: [expectation], timeout: 5.0)
        XCTAssertGreaterThan(eventCount, 0)
    }
}
