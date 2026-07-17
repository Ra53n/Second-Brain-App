// CronExpressionTests.swift — cron-парсер задачи 36: валидные/невалидные
// выражения, `*/N`, списки, диапазоны, weekday 0/7, vixie-OR-правило
// день/день-недели, nextDate через границы суток/месяца/года, лимит перебора.
// Календарь фиксирован (Europe/Moscow, без DST) — тесты детерминированы.

import XCTest
@testable import SecondBrain

final class CronExpressionTests: XCTestCase {
    /// Григорианский календарь в зоне без DST — детерминизм matches/nextDate.
    private var moscow: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()

    /// Дата в московской зоне (короче, чем DateComponents в каждом тесте).
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int,
                      second: Int = 0) -> Date {
        moscow.date(from: DateComponents(year: y, month: mo, day: d,
                                         hour: h, minute: mi, second: second))!
    }

    // MARK: - Парсинг

    func testParseValidExpressions() {
        XCTAssertNotNil(CronExpression.parse("* * * * *"))
        XCTAssertNotNil(CronExpression.parse("0 9 * * 1-5"))
        XCTAssertNotNil(CronExpression.parse("*/15 * * * *"))
        XCTAssertNotNil(CronExpression.parse("0,30 8-18 1,15 */2 0"))
        XCTAssertNotNil(CronExpression.parse("1-30/5 * * * *"))
        XCTAssertNotNil(CronExpression.parse("  0   9  *  *  * "), "лишние пробелы допустимы")
    }

    func testParseInvalidExpressions() {
        XCTAssertNil(CronExpression.parse(""), "пустая строка")
        XCTAssertNil(CronExpression.parse("* * * *"), "4 поля")
        XCTAssertNil(CronExpression.parse("* * * * * *"), "6 полей")
        XCTAssertNil(CronExpression.parse("60 * * * *"), "минута вне диапазона")
        XCTAssertNil(CronExpression.parse("* 24 * * *"), "час вне диапазона")
        XCTAssertNil(CronExpression.parse("* * 0 * *"), "день 0")
        XCTAssertNil(CronExpression.parse("* * 32 * *"), "день 32")
        XCTAssertNil(CronExpression.parse("* * * 13 *"), "месяц 13")
        XCTAssertNil(CronExpression.parse("* * * * 8"), "день недели 8")
        XCTAssertNil(CronExpression.parse("abc * * * *"), "мусор")
        XCTAssertNil(CronExpression.parse("*/0 * * * *"), "нулевой шаг")
        XCTAssertNil(CronExpression.parse("5-1 * * * *"), "перевёрнутый диапазон")
        XCTAssertNil(CronExpression.parse("1,,2 * * * *"), "пустой элемент списка")
        XCTAssertNil(CronExpression.parse("1-2-3 * * * *"), "двойной диапазон")
    }

    func testParseStepAndRangeAndList() throws {
        let cron = try XCTUnwrap(CronExpression.parse("*/20 1-3 1,15 * *"))
        XCTAssertEqual(cron.minutes, [0, 20, 40])
        XCTAssertEqual(cron.hours, [1, 2, 3])
        XCTAssertEqual(cron.days, [1, 15])
        XCTAssertEqual(cron.months, Set(1...12))
    }

    func testParseRangeWithStep() throws {
        let cron = try XCTUnwrap(CronExpression.parse("1-30/10 * * * *"))
        XCTAssertEqual(cron.minutes, [1, 11, 21])
    }

    func testWeekdaySevenNormalizesToSunday() throws {
        let seven = try XCTUnwrap(CronExpression.parse("0 0 * * 7"))
        let zero = try XCTUnwrap(CronExpression.parse("0 0 * * 0"))
        XCTAssertEqual(seven.weekdays, zero.weekdays)
        XCTAssertEqual(seven.weekdays, [0])
    }

    // MARK: - Матчинг

    func testMatchesWeekday() throws {
        let cron = try XCTUnwrap(CronExpression.parse("0 9 * * 1-5"))
        // 2026-07-17 — пятница, 2026-07-18 — суббота.
        XCTAssertTrue(cron.matches(date(2026, 7, 17, 9, 0), calendar: moscow))
        XCTAssertFalse(cron.matches(date(2026, 7, 18, 9, 0), calendar: moscow))
        XCTAssertFalse(cron.matches(date(2026, 7, 17, 9, 1), calendar: moscow))
    }

    func testMatchesSundayBothNotations() throws {
        // 2026-07-19 — воскресенье.
        let sunday = date(2026, 7, 19, 12, 0)
        for expr in ["0 12 * * 0", "0 12 * * 7"] {
            let cron = try XCTUnwrap(CronExpression.parse(expr))
            XCTAssertTrue(cron.matches(sunday, calendar: moscow), expr)
        }
    }

    func testDayWeekdayORWhenBothRestricted() throws {
        // vixie-правило: оба поля ограничены → совпадение ЛЮБОГО из них.
        let cron = try XCTUnwrap(CronExpression.parse("0 0 15 * 1"))
        // 2026-07-15 — среда (не понедельник), но 15-е число → подходит.
        XCTAssertTrue(cron.matches(date(2026, 7, 15, 0, 0), calendar: moscow))
        // 2026-07-20 — понедельник (не 15-е) → тоже подходит.
        XCTAssertTrue(cron.matches(date(2026, 7, 20, 0, 0), calendar: moscow))
        // 2026-07-16 — четверг, 16-е → нет.
        XCTAssertFalse(cron.matches(date(2026, 7, 16, 0, 0), calendar: moscow))
    }

    func testDayWeekdayANDWhenOneIsWildcard() throws {
        // День-недели `*` → обычное AND по дню месяца.
        let cron = try XCTUnwrap(CronExpression.parse("0 0 15 * *"))
        XCTAssertTrue(cron.matches(date(2026, 7, 15, 0, 0), calendar: moscow))
        XCTAssertFalse(cron.matches(date(2026, 7, 20, 0, 0), calendar: moscow))
    }

    // MARK: - nextDate

    func testNextDateWithinHour() throws {
        let cron = try XCTUnwrap(CronExpression.parse("*/15 * * * *"))
        XCTAssertEqual(cron.nextDate(after: date(2026, 7, 18, 10, 3), calendar: moscow),
                       date(2026, 7, 18, 10, 15))
        // Строго после: с ровного слота уходим на следующий.
        XCTAssertEqual(cron.nextDate(after: date(2026, 7, 18, 10, 15), calendar: moscow),
                       date(2026, 7, 18, 10, 30))
        // Секунды обрезаются: 10:15:30 → следующая граница минуты — 10:16 → слот 10:30.
        XCTAssertEqual(cron.nextDate(after: date(2026, 7, 18, 10, 15, second: 30),
                                     calendar: moscow),
                       date(2026, 7, 18, 10, 30))
    }

    func testNextDateCrossesDayBoundary() throws {
        let cron = try XCTUnwrap(CronExpression.parse("0 9 * * *"))
        XCTAssertEqual(cron.nextDate(after: date(2026, 7, 18, 10, 0), calendar: moscow),
                       date(2026, 7, 19, 9, 0))
    }

    func testNextDateCrossesMonthBoundary() throws {
        let cron = try XCTUnwrap(CronExpression.parse("0 0 1 * *"))
        XCTAssertEqual(cron.nextDate(after: date(2026, 7, 18, 0, 0), calendar: moscow),
                       date(2026, 8, 1, 0, 0))
    }

    func testNextDateCrossesYearBoundary() throws {
        let cron = try XCTUnwrap(CronExpression.parse("30 6 1 1 *"))
        XCTAssertEqual(cron.nextDate(after: date(2026, 7, 18, 0, 0), calendar: moscow),
                       date(2027, 1, 1, 6, 30))
    }

    func testNextDateFindsLeapDay() throws {
        let cron = try XCTUnwrap(CronExpression.parse("0 0 29 2 *"))
        XCTAssertEqual(cron.nextDate(after: date(2026, 7, 18, 0, 0), calendar: moscow),
                       date(2028, 2, 29, 0, 0), "29 февраля в пределах горизонта 4 года")
    }

    func testNextDateImpossibleExpressionReturnsNil() throws {
        let cron = try XCTUnwrap(CronExpression.parse("0 0 31 2 *"))
        XCTAssertNil(cron.nextDate(after: date(2026, 7, 18, 0, 0), calendar: moscow),
                     "31 февраля не существует — nil, а не вечный цикл")
    }

    func testNextDateAcrossDSTGap() throws {
        // Europe/Berlin, 2026-03-29: 02:00→03:00, локального 02:30 не существует.
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let cron = try XCTUnwrap(CronExpression.parse("30 2 * * *"))
        let before = berlin.date(from: DateComponents(year: 2026, month: 3, day: 29,
                                                      hour: 1, minute: 0))!
        let next = try XCTUnwrap(cron.nextDate(after: before, calendar: berlin))
        // Слот 29 марта пропущен (часа не было) — следующий валидный 30 марта.
        let c = berlin.dateComponents([.day, .hour, .minute], from: next)
        XCTAssertEqual(c.day, 30)
        XCTAssertEqual(c.hour, 2)
        XCTAssertEqual(c.minute, 30)
    }
}
