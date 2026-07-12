// RecordingNamer.swift — имена файлов записей встреч.
//
// Формат из задачи 06: "YYYY-MM-DD HH-mm" — сортируется хронологически как
// строка и читается человеком в Finder/Obsidian. Коллизии (две записи в одну
// минуту) решаются суффиксом " (2)". Дорожка системного звука в режиме .both
// получает суффикс " (система)" к базовому имени.

import Foundation

enum RecordingNamer {
    /// Суффикс имени файла системной дорожки в комбинированном режиме.
    static let systemTrackSuffix = " (система)"

    /// Длина базового имени без суффикса коллизии: "2026-07-12 10-30".
    private static let baseNameLength = 16

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX") // стабильный формат вне зависимости от локали
        f.timeZone = .current                        // имена в местном времени — так их ищет пользователь
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()

    /// Базовое имя записи (без расширения) для даты.
    static func baseName(for date: Date) -> String {
        formatter.string(from: date)
    }

    /// Базовое имя, не конфликтующее с существующими: "…", "… (2)", "… (3)".
    /// `taken` отвечает, занято ли имя-кандидат (проверку по всем расширениям
    /// и суффиксам дорожек делает вызывающая сторона).
    static func uniqueBaseName(for date: Date, taken: (String) -> Bool) -> String {
        let base = baseName(for: date)
        guard taken(base) else { return base }
        var n = 2
        while taken("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    /// Обратный разбор: дата из базового имени (суффиксы " (2)" и " (система)"
    /// игнорируются). Используется восстановлением после краша, когда sidecar
    /// с метаданными не успел записаться.
    static func date(fromBaseName base: String) -> Date? {
        guard base.count >= baseNameLength else { return nil }
        return formatter.date(from: String(base.prefix(baseNameLength)))
    }
}
