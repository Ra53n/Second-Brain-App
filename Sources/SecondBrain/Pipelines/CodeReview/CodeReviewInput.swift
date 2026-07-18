// CodeReviewInput.swift — сборка входа ревью (задача 37): чистые функции.
//
// Diff режется по файлам (заголовки «diff --git»), большие диффы группируются
// в чанки для map-сжатия (см. CodeReviewRunner.condense; паттерн чанкования —
// MeetingPrompts.chunkTranscript). Итоговый input — секции [PR] / [DIFF] /
// [PROJECT_DOCS] / [TESTS]. Всё, что с LLM/сетью/диском, живёт в раннере —
// здесь только тестируемая без окружения логика.
//
// Лимиты (символы; документированы по подсказке задачи — diff огромного PR
// не влезет в контекст локальной модели):
//  - maxDiffChars: порог map-сжатия — меньше уходит целиком, 0 LLM-вызовов;
//  - maxChunkChars: размер чанка map-фазы (как maxTranscriptChars встреч);
//  - maxFileChars: кап одного файла — генерённые простыни режутся с пометкой;
//  - maxCondensedChars: кап секции [DIFF] после сжатия (страховка);
//  - maxTestsChars: кап секции [TESTS] (только списки путей).

import Foundation

enum CodeReviewInput {
    static let maxDiffChars = 24_000
    static let maxChunkChars = 24_000
    static let maxFileChars = 12_000
    static let maxCondensedChars = 30_000
    static let maxTestsChars = 4_000

    // MARK: - Разбор диффа

    /// Diff одного файла: путь (b-сторона) + полный текст его секции.
    struct FileDiff: Equatable {
        var path: String
        var text: String
    }

    /// Режет unified diff по заголовкам «diff --git a/… b/…». Текст до первого
    /// заголовка (преамбулы нет в выводе git, но вдруг) отбрасывается.
    static func splitByFile(_ diff: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var currentPath: String?
        var currentLines: [String] = []

        func flush() {
            guard let path = currentPath else { return }
            files.append(FileDiff(path: path,
                                  text: currentLines.joined(separator: "\n")))
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                // «diff --git a/path b/path» — берём b-путь (итоговое имя
                // после переименования).
                let parts = line.split(separator: " ")
                let bPart = parts.last.map(String.init) ?? ""
                currentPath = bPart.hasPrefix("b/") ? String(bPart.dropFirst(2)) : bPart
                currentLines = [String(line)]
            } else if currentPath != nil {
                currentLines.append(String(line))
            }
        }
        flush()
        return files
    }

    /// Жадная группировка файлов в чанки ≤ maxChars (порядок сохраняется).
    /// Файл длиннее капа режется с пометкой — ревьюеру важнее начало диффа.
    static func packChunks(_ files: [FileDiff], maxChars: Int = maxChunkChars) -> [String] {
        var chunks: [String] = []
        var current = ""
        for file in files {
            var text = file.text
            if text.count > maxFileChars {
                text = String(text.prefix(maxFileChars))
                    + "\n…(diff файла \(file.path) обрезан: \(file.text.count) символов)"
            }
            if !current.isEmpty, current.count + text.count + 2 > maxChars {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? text : "\n\n" + text
            // Одинокий файл может сам превысить лимит чанка — отдаём как есть,
            // он уже обрезан капом файла.
            if current.count >= maxChars {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Секция тестов

    /// Затронутые и соседние тесты — эвристика по именам, без парсинга Swift:
    /// затронутые = изменённые пути в Tests/ либо *Tests.swift; соседние =
    /// для изменённого Foo.swift ищется FooTests.swift среди tracked-файлов.
    /// Оговорка: осмысленно, когда projectRepoPath указывает на репозиторий PR.
    static func testsSection(changedPaths: [String], trackedFiles: [String]) -> String {
        func isTestPath(_ path: String) -> Bool {
            path.contains("Tests/") || path.hasSuffix("Tests.swift")
        }
        let affected = changedPaths.filter(isTestPath)
        let changedTypes = changedPaths
            .filter { !isTestPath($0) && $0.hasSuffix(".swift") }
            .map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "") }
        let neighborNames = Set(changedTypes.map { "\($0)Tests.swift" })
        let neighbors = trackedFiles.filter { file in
            neighborNames.contains((file as NSString).lastPathComponent)
        }

        var lines: [String] = []
        if !affected.isEmpty {
            lines.append("Изменённые тесты:")
            lines += affected.map { "- \($0)" }
        }
        let newNeighbors = neighbors.filter { !affected.contains($0) }
        if !newNeighbors.isEmpty {
            lines.append("Тесты изменённых типов (не тронуты в diff):")
            lines += newNeighbors.map { "- \($0)" }
        }
        if lines.isEmpty {
            lines.append("Тесты по именам изменённых файлов не найдены.")
        }
        lines.append("Содержимое тестов при необходимости читай инструментом read_file.")
        let section = lines.joined(separator: "\n")
        if section.count > maxTestsChars {
            return String(section.prefix(maxTestsChars)) + "\n…(список обрезан)"
        }
        return section
    }

    // MARK: - Сборка input

    /// Полный input прогона: секции в фиксированном порядке, пустые опускаются.
    static func assemble(pr: String?, diff: String,
                         docs: String?, tests: String?) -> String {
        var sections: [String] = []
        if let pr, !pr.isEmpty {
            sections.append("[PR]\n\(pr)")
        }
        sections.append("[DIFF]\n\(diff)")
        if let docs, !docs.isEmpty {
            sections.append("[PROJECT_DOCS]\n\(docs)")
        }
        if let tests, !tests.isEmpty {
            sections.append("[TESTS]\n\(tests)")
        }
        return sections.joined(separator: "\n\n")
    }
}
