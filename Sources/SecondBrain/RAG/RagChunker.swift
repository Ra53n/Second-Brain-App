// RagChunker.swift — структурный чанкер markdown-заметок (задача 13).
//
// Основа — StructureChunker из MA, адаптированный под наши метаданные:
// чанк несёт ЗАГОЛОВОЧНЫЙ ПУТЬ («H1 > H2», а не только ближайший заголовок)
// и диапазон строк (1-based) — так ретрив (14) подписывает источники, а UI
// может прыгнуть к месту в заметке. Заголовки внутри код-блоков (``` … ```)
// заголовками НЕ считаются. Слишком длинные разделы дорезаются по абзацам
// (вторичная нарезка сохраняет заголовочный путь; диапазон строк — по
// фактическим строкам куска).

import Foundation

/// Чанк заметки: единица индексации и ретрива.
struct RagChunk: Equatable {
    var filePath: String     // относительный путь заметки в vault
    var headingPath: String  // «H1 > H2»; преамбула до заголовков — пустая строка
    var lineStart: Int       // 1-based, включительно
    var lineEnd: Int
    var text: String
}

enum MarkdownChunker {
    /// Потолок длины чанка в символах (примерно 500–700 токенов).
    static let defaultMaxChars = 2000

    /// Режет текст заметки на чанки по структуре заголовков.
    /// Пустой/пробельный текст → пустой массив.
    static func chunk(text: String,
                      filePath: String,
                      maxChars: Int = defaultMaxChars) -> [RagChunk] {
        let lines = text.components(separatedBy: "\n")

        // Раздел: заголовочный путь + строки тела (заголовок включён в тело —
        // он несёт смысл для эмбеддинга).
        struct Section {
            var headingPath: String
            var lineStart: Int
            var lines: [String]
        }

        var sections: [Section] = []
        // Стек заголовков: (уровень, текст) — путь строится из него.
        var headingStack: [(level: Int, title: String)] = []
        var current = Section(headingPath: "", lineStart: 1, lines: [])
        var inCodeFence = false

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeFence.toggle()
            }
            if !inCodeFence, let heading = headingTitle(line) {
                if !current.lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    sections.append(current)
                }
                // Обновляем стек: срезаем уровни ≥ текущего, кладём новый.
                headingStack.removeAll { $0.level >= heading.level }
                headingStack.append((heading.level, heading.title))
                current = Section(
                    headingPath: headingStack.map(\.title).joined(separator: " > "),
                    lineStart: lineNumber,
                    lines: [line])
            } else {
                current.lines.append(line)
            }
        }
        if !current.lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            sections.append(current)
        }

        // Разделы → чанки (длинные дорезаются по абзацам).
        var chunks: [RagChunk] = []
        for section in sections {
            let body = section.lines.joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if body.count <= maxChars {
                chunks.append(RagChunk(filePath: filePath,
                                       headingPath: section.headingPath,
                                       lineStart: section.lineStart,
                                       lineEnd: section.lineStart + section.lines.count - 1,
                                       text: body))
            } else {
                chunks.append(contentsOf: splitLongSection(section.lines,
                                                           startLine: section.lineStart,
                                                           headingPath: section.headingPath,
                                                           filePath: filePath,
                                                           maxChars: maxChars))
            }
        }
        return chunks
    }

    /// Вторичная нарезка длинного раздела: копим строки до maxChars, режем на
    /// границе строки (грубая граница абзаца); строка-монстр длиннее лимита
    /// становится собственным чанком (не дробим строку — теряются смыслы).
    private static func splitLongSection(_ lines: [String],
                                         startLine: Int,
                                         headingPath: String,
                                         filePath: String,
                                         maxChars: Int) -> [RagChunk] {
        var chunks: [RagChunk] = []
        var buffer: [String] = []
        var bufferStart = startLine
        var bufferChars = 0

        func flush(endLine: Int) {
            let text = buffer.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(RagChunk(filePath: filePath,
                                       headingPath: headingPath,
                                       lineStart: bufferStart,
                                       lineEnd: endLine,
                                       text: text))
            }
            buffer = []
            bufferChars = 0
        }

        for (offset, line) in lines.enumerated() {
            let lineNumber = startLine + offset
            if bufferChars + line.count > maxChars, !buffer.isEmpty {
                flush(endLine: lineNumber - 1)
                bufferStart = lineNumber
            }
            buffer.append(line)
            bufferChars += line.count + 1
        }
        flush(endLine: startLine + lines.count - 1)
        return chunks
    }

    /// ATX-заголовок markdown: уровень и текст («## Планы» → (2, «Планы»)).
    /// Требуется пробел после решёток (CommonMark); иначе nil.
    static func headingTitle(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.first == "#" else { return nil }
        var hashes = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == "#" {
            hashes += 1
            index = trimmed.index(after: index)
        }
        guard (1...6).contains(hashes), index < trimmed.endIndex, trimmed[index] == " " else {
            return nil
        }
        let title = String(trimmed[index...]).trimmingCharacters(in: .whitespaces)
        return (hashes, title)
    }
}
