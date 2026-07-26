// NoteTemplate.swift — рендер плейсхолдеров шаблона заметки: {{date}}/{{title}}.

import Foundation

/// Подстановка плейсхолдеров при создании заметки из Templates/ (задача 79,
/// формат даты как в PipelineTemplate.render). Незнакомые плейсхолдеры
/// (опечатка вида {{Date}}) остаются в тексте как есть.
enum NoteTemplate {
    /// Папка шаблонов — в корне vault, зарезервированное имя (аналог Meetings/).
    static let folderName = "Templates"

    static func render(_ template: String,
                       title: String,
                       date: Date = Date(),
                       timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return template
            .replacingOccurrences(of: "{{date}}", with: formatter.string(from: date))
            .replacingOccurrences(of: "{{title}}", with: title)
    }
}
