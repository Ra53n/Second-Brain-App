// RecordingNamerTests.swift — имена файлов записей: формат, коллизии,
// обратный разбор даты из имени (нужен восстановлению после краша).

import XCTest
@testable import SecondBrain

final class RecordingNamerTests: XCTestCase {

    /// Дата в местной таймзоне (имена файлов — в местном времени).
    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        (components.year, components.month, components.day) = (year, month, day)
        (components.hour, components.minute) = (hour, minute)
        return Calendar.current.date(from: components)!
    }

    func testBaseNameFormat() {
        XCTAssertEqual(RecordingNamer.baseName(for: date(2026, 7, 12, 9, 5)),
                       "2026-07-12 09-05")
        XCTAssertEqual(RecordingNamer.baseName(for: date(2026, 12, 31, 23, 59)),
                       "2026-12-31 23-59")
    }

    func testUniqueBaseNameWithoutCollision() {
        let name = RecordingNamer.uniqueBaseName(for: date(2026, 7, 12, 10, 30)) { _ in false }
        XCTAssertEqual(name, "2026-07-12 10-30")
    }

    func testUniqueBaseNameResolvesCollisions() {
        // Заняты базовое имя и " (2)" — следующая запись получает " (3)".
        let taken: Set<String> = ["2026-07-12 10-30", "2026-07-12 10-30 (2)"]
        let name = RecordingNamer.uniqueBaseName(for: date(2026, 7, 12, 10, 30)) { taken.contains($0) }
        XCTAssertEqual(name, "2026-07-12 10-30 (3)")
    }

    func testDateFromBaseNameRoundTrip() {
        let original = date(2026, 7, 12, 10, 30)
        let base = RecordingNamer.baseName(for: original)
        XCTAssertEqual(RecordingNamer.date(fromBaseName: base), original)
    }

    func testDateFromBaseNameIgnoresCollisionSuffix() {
        XCTAssertEqual(RecordingNamer.date(fromBaseName: "2026-07-12 10-30 (2)"),
                       date(2026, 7, 12, 10, 30))
    }

    func testDateFromGarbageIsNil() {
        XCTAssertNil(RecordingNamer.date(fromBaseName: "заметка о встрече"))
        XCTAssertNil(RecordingNamer.date(fromBaseName: ""))
    }
}
