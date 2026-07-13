// MeetingNoteWriter.swift — итоговая заметка встречи в vault.
//
// Путь: <vault>/<папка>/YYYY-MM-DD <Название>.md. Правила:
//  - название чистится для файловой системы (/, :, … → «-»), пустое → «Встреча»;
//  - папка от LLM валидируется против реального дерева vault; несуществующая →
//    фолбэк в дефолтную Meetings/YYYY-MM (пользователю показывается флаг);
//  - коллизия имён решается суффиксом « (2)» — существующие файлы НЕ
//    перезаписываются (инвариант №1: vault — источник истины);
//  - содержимое: frontmatter (дата, длительность, провайдер, ссылки на аудио) +
//    summary + полный транскрипт с таймкодами по дорожкам.

import Foundation

enum MeetingNoteWriter {

    // MARK: - Название

    /// Чистит название для файловой системы: запрещённые символы → «-»,
    /// схлопывает пробелы, обрезает до 80 символов; пустое → «Встреча».
    static func sanitizeTitle(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
            .union(.newlines)
            .union(.controlCharacters)
        var cleaned = ""
        for scalar in raw.unicodeScalars {
            cleaned.unicodeScalars.append(forbidden.contains(scalar) ? "-" : scalar)
        }
        // Схлопываем повторные пробелы/дефисы, образовавшиеся после замен.
        while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
        while cleaned.contains("--") { cleaned = cleaned.replacingOccurrences(of: "--", with: "-") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-.")))
        if cleaned.count > 80 {
            cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? "Встреча" : cleaned
    }

    // MARK: - Папка

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Дефолтная папка встреч: Meetings/YYYY-MM.
    static func defaultFolder(for date: Date) -> String {
        "Meetings/\(folderFormatter.string(from: date))"
    }

    /// Валидация предложения LLM против реального дерева vault: несуществующая
    /// папка → фолбэк в дефолтную (wasInvalid=true — UI покажет пользователю).
    /// Пустое предложение — не ошибка, просто дефолт. customDefault —
    /// пользовательская папка по умолчанию из настроек (задача 17); пустая
    /// строка — штатная Meetings/YYYY-MM.
    static func resolveFolder(suggested: String?,
                              existingFolders: [String],
                              date: Date,
                              customDefault: String = "") -> (folder: String, wasInvalid: Bool) {
        let trimmedCustom = customDefault
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/")))
        let fallback = trimmedCustom.isEmpty ? defaultFolder(for: date) : trimmedCustom
        guard let suggested else { return (fallback, false) }
        let normalized = suggested
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/")))
        guard !normalized.isEmpty else { return (fallback, false) }
        // Дефолтная папка (и подпапки Meetings) — всегда легальны, даже если ещё не созданы.
        if normalized == fallback || normalized.hasPrefix("Meetings/") || normalized == "Meetings" {
            return (normalized, false)
        }
        let known = Set(existingFolders.map {
            $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/")))
        })
        return known.contains(normalized) ? (normalized, false) : (fallback, true)
    }

    // MARK: - Путь заметки

    /// Относительный путь заметки: <папка>/YYYY-MM-DD <Название>.md;
    /// коллизия → « (2)», « (3)»… `exists` отвечает по относительному пути.
    static func notePath(folder: String,
                         date: Date,
                         title: String,
                         exists: (String) -> Bool) -> String {
        let base = "\(dayFormatter.string(from: date)) \(sanitizeTitle(title))"
        let folderPrefix = folder.isEmpty ? "" : "\(folder)/"
        var candidate = "\(folderPrefix)\(base).md"
        var n = 2
        while exists(candidate) {
            candidate = "\(folderPrefix)\(base) (\(n)).md"
            n += 1
        }
        return candidate
    }

    // MARK: - Содержимое заметки

    /// Markdown-заметка: frontmatter + summary + транскрипт с таймкодами.
    static func noteContent(context: MeetingContext) -> String {
        var lines: [String] = ["---"]
        lines.append("date: \(ISO8601DateFormatter().string(from: context.recordedAt))")
        lines.append("duration: \(formatDuration(context.duration))")
        if let provider = context.transcriptionProviderID {
            lines.append("transcription: \(provider)")
        }
        if !context.audioFiles.isEmpty {
            lines.append("audio:")
            for file in context.audioFiles {
                lines.append("  - \"[[\(file)]]\"")
            }
        }
        lines.append("---")
        lines.append("")
        lines.append("# \(sanitizeTitle(context.effectiveTitle))")
        lines.append("")
        if !context.summary.isEmpty {
            lines.append("## Саммари")
            lines.append("")
            lines.append(context.summary)
            lines.append("")
        }
        lines.append("## Транскрипт")
        lines.append("")
        for track in context.transcripts {
            if context.transcripts.count > 1 {
                lines.append("### \(track.label)")
                lines.append("")
            }
            lines.append(transcriptBody(track.transcript))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Тело транскрипта: сегменты с таймкодами, без сегментов — сплошной текст.
    private static func transcriptBody(_ transcript: Transcript) -> String {
        guard !transcript.segments.isEmpty else { return transcript.fullText }
        return transcript.segments.map { segment in
            if let start = segment.start {
                return "[\(formatTimecode(start))] \(segment.text)"
            }
            return segment.text
        }.joined(separator: "\n")
    }

    /// «мм:сс» до часа, дальше «ч:мм:сс».
    static func formatTimecode(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    /// «32 мин» / «1 ч 05 мин» — для frontmatter.
    static func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((interval / 60).rounded())
        let (h, m) = (totalMinutes / 60, totalMinutes % 60)
        return h > 0 ? "\(h) ч \(String(format: "%02d", m)) мин" : "\(m) мин"
    }

    // MARK: - Запись

    /// Пишет заметку по относительному пути, создавая промежуточные папки.
    /// Существующий файл НЕ перезаписывается (коллизии решает notePath, это
    /// последний рубеж), запись атомарная.
    @discardableResult
    static func write(content: String, relativePath: String, vaultURL: URL) throws -> URL {
        let target = vaultURL.appendingPathComponent(relativePath)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw MeetingError.noteWriteFailed("файл уже существует: \(relativePath)")
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: target, options: .atomic)
        } catch {
            throw MeetingError.noteWriteFailed(error.localizedDescription)
        }
        return target
    }
}
