// CronExpression.swift — минимальный cron-парсер (задача 36).
//
// 5 полей: минута час день месяц день-недели. Поддержка: `*`, `*/N`, списки
// `a,b`, диапазоны `a-b` и комбинации (`1-5,10`, `1-30/5`). Своим кодом, без
// зависимостей: библиотека ради пяти полей не нужна (подсказка задачи; MA
// использует croner, но там сервер 24/7 и 6-польный формат).
//
// Семантика — vixie-cron:
//  - день-недели 0–7, где 0 и 7 = воскресенье (7 нормализуется в 0);
//  - если ограничены (не `*`) ОБА поля «день месяца» и «день недели», дата
//    подходит при совпадении ЛЮБОГО из них (OR); иначе — обычное AND.

import Foundation

/// Распарсенное cron-выражение. Чистая структура без таймеров: matches и
/// nextDate тестируются мок-датами, планировщик лишь дергает их раз в минуту.
struct CronExpression: Equatable {
    let minutes: Set<Int>     // 0-59
    let hours: Set<Int>       // 0-23
    let days: Set<Int>        // 1-31
    let months: Set<Int>      // 1-12
    let weekdays: Set<Int>    // 0-6 (0 = воскресенье; 7 на входе → 0)
    /// Было ли поле `*` в исходном выражении — нужно для OR-правила
    /// день/день-недели (см. шапку файла).
    let dayIsWildcard: Bool
    let weekdayIsWildcard: Bool

    /// Горизонт перебора nextDate: ~4 года покрывают самый редкий валидный
    /// слот (29 февраля); дальше выражение считается «никогда» → nil.
    private static let lookaheadMinutes = 4 * 366 * 24 * 60

    // MARK: - Парсинг

    /// nil — выражение невалидно (не 5 полей, мусор, выход за диапазон, */0).
    static func parse(_ expression: String) -> CronExpression? {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard fields.count == 5 else { return nil }
        guard let minutes = parseField(fields[0], range: 0...59),
              let hours = parseField(fields[1], range: 0...23),
              let days = parseField(fields[2], range: 1...31),
              let months = parseField(fields[3], range: 1...12),
              // День-недели парсим в 0...7, затем сворачиваем 7 → 0.
              let rawWeekdays = parseField(fields[4], range: 0...7)
        else { return nil }
        let weekdays = Set(rawWeekdays.map { $0 == 7 ? 0 : $0 })
        return CronExpression(minutes: minutes, hours: hours, days: days,
                              months: months, weekdays: weekdays,
                              dayIsWildcard: fields[2] == "*",
                              weekdayIsWildcard: fields[4] == "*")
    }

    /// Одно поле: список элементов через запятую; элемент — `*`, `*/N`, `a`,
    /// `a-b`, `a-b/N`. Возвращает множество допустимых значений или nil.
    private static func parseField(_ field: String, range: ClosedRange<Int>) -> Set<Int>? {
        var result: Set<Int> = []
        for element in field.split(separator: ",", omittingEmptySubsequences: false) {
            guard let values = parseElement(String(element), range: range) else { return nil }
            result.formUnion(values)
        }
        return result.isEmpty ? nil : result
    }

    private static func parseElement(_ element: String, range: ClosedRange<Int>) -> Set<Int>? {
        // Отделяем шаг: `<база>/N`.
        let parts = element.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        var step = 1
        if parts.count == 2 {
            guard let s = Int(parts[1]), s >= 1 else { return nil } // `*/0` невалиден
            step = s
        }

        let base = String(parts[0])
        let span: ClosedRange<Int>
        if base == "*" {
            span = range
        } else if base.contains("-") {
            let bounds = base.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2,
                  let lo = Int(bounds[0]), let hi = Int(bounds[1]),
                  lo <= hi, range.contains(lo), range.contains(hi) else { return nil }
            span = lo...hi
        } else {
            guard let value = Int(base), range.contains(value) else { return nil }
            // Одиночное значение со шагом (`5/10`) в vixie-cron легально,
            // но бессмысленно — трактуем как само значение.
            return [value]
        }
        return Set(stride(from: span.lowerBound, through: span.upperBound, by: step))
    }

    // MARK: - Матчинг

    /// Совпадает ли дата (с точностью до минуты) со слотом выражения.
    func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = c.minute, let hour = c.hour,
              let day = c.day, let month = c.month, let weekday = c.weekday else { return false }
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else {
            return false
        }
        // Calendar.weekday: 1 = воскресенье … 7 = суббота → cron 0-6.
        let cronWeekday = weekday - 1
        let dayMatch = days.contains(day)
        let weekdayMatch = weekdays.contains(cronWeekday)
        if !dayIsWildcard && !weekdayIsWildcard {
            return dayMatch || weekdayMatch // vixie-OR: оба поля ограничены
        }
        return dayMatch && weekdayMatch
    }

    /// Ближайший слот строго после date (секунды обнуляются). nil — слот не
    /// найден за горизонтом lookahead (например, `0 0 31 2 *`).
    /// Перебор с покомпонентными скачками (не совпал месяц → начало следующего
    /// месяца, день → следующий день, час → следующий час): даже «никогда»-
    /// выражение обходит горизонт за сотни итераций, а DST обрабатывается
    /// естественно — несуществующий локальный час просто пропускается.
    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        let horizon = date.addingTimeInterval(Double(Self.lookaheadMinutes) * 60)
        // Обнуляем секунды и субсекунды, затем стартуем со следующей минуты.
        let seconds = calendar.component(.second, from: date)
        let sub = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        var candidate = date.addingTimeInterval(-Double(seconds) - sub + 60)
        // Страховка от вырожденного календаря: скачки гарантированно движутся
        // вперёд, так что лимит с запасом больше любого честного обхода.
        var iterations = 0
        while candidate <= horizon, iterations < 200_000 {
            iterations += 1
            let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday],
                                            from: candidate)
            guard let minute = c.minute, let hour = c.hour,
                  let day = c.day, let month = c.month, let weekday = c.weekday,
                  let monthStart = calendar.date(
                      from: calendar.dateComponents([.year, .month], from: candidate)),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
                  let nextDay = calendar.date(byAdding: .day, value: 1,
                                              to: calendar.startOfDay(for: candidate)),
                  let nextHour = calendar.date(byAdding: .hour, value: 1,
                                               to: candidate.addingTimeInterval(-Double(minute) * 60))
            else { return nil }
            if !months.contains(month) { candidate = nextMonth; continue }
            let cronWeekday = weekday - 1 // Calendar.weekday: 1 = воскресенье
            let dayOK = (!dayIsWildcard && !weekdayIsWildcard)
                ? days.contains(day) || weekdays.contains(cronWeekday)
                : days.contains(day) && weekdays.contains(cronWeekday)
            if !dayOK { candidate = nextDay; continue }
            if !hours.contains(hour) { candidate = nextHour; continue }
            if !minutes.contains(minute) { candidate = candidate.addingTimeInterval(60); continue }
            return candidate
        }
        return nil
    }
}
