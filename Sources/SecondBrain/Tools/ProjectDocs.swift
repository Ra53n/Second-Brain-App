// ProjectDocs.swift — документация выбранного проекта для /help (задача 22).
//
// Загрузка README + docs/*.md выбранного репозитория и сборка блока
// [PROJECT_DOCS] под бюджет символов: README приоритетен, каждый файл
// отделён заголовком, переполнение обрезается с пометкой. Бюджет в символах
// (~4 символа/токен): 32 000 ≈ 8 тыс. токенов — настраиваемость в бэклоге.

import Foundation

/// Загрузка докфайлов репозитория: README.md в корне + docs/*.md.
enum ProjectDocsLoader {
    /// Файл больше этого размера пропускается (это не документация, а свалка).
    static let maxFileBytes = 256 * 1024

    /// (имя, содержимое) в порядке приоритета: README первым, docs/ по алфавиту.
    static func loadFiles(repoRoot: URL) -> [(name: String, content: String)] {
        var result: [(String, String)] = []
        let fm = FileManager.default

        // README.md без учёта регистра (README.md / readme.md / Readme.md).
        if let rootFiles = try? fm.contentsOfDirectory(atPath: repoRoot.path),
           let readme = rootFiles.first(where: { $0.lowercased() == "readme.md" }),
           let content = readText(repoRoot.appendingPathComponent(readme)) {
            result.append((readme, content))
        }

        let docsDir = repoRoot.appendingPathComponent("docs")
        if let docFiles = try? fm.contentsOfDirectory(atPath: docsDir.path) {
            for file in docFiles.sorted() where file.lowercased().hasSuffix(".md") {
                if let content = readText(docsDir.appendingPathComponent(file)) {
                    result.append(("docs/\(file)", content))
                }
            }
        }
        return result
    }

    private static func readText(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size <= maxFileBytes else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Сборка блока [PROJECT_DOCS] из файлов под бюджет символов.
enum ProjectDocsContext {
    /// README (первый файл) получает приоритет естественно: файлы кладутся
    /// по порядку, пока есть бюджет; не влезший обрезается с пометкой,
    /// последующие пропускаются с перечислением имён. Бюджет в символах —
    /// ~4 символа на токен; дефолт 32000 = ~8 тыс. токенов.
    static func build(files: [(name: String, content: String)],
                      budget: Int = 32_000) -> String {
        guard !files.isEmpty else { return "" }
        var parts: [String] = []
        var remaining = budget
        var skipped: [String] = []

        for (name, content) in files {
            let header = "=== \(name) ===\n"
            guard remaining > header.count + 200 else {
                // Меньше ~200 символов пользы не принесёт — файл в пропущенные.
                skipped.append(name)
                continue
            }
            let available = remaining - header.count
            if content.count <= available {
                parts.append(header + content)
                remaining -= header.count + content.count
            } else {
                let cut = String(content.prefix(available))
                parts.append(header + cut + "\n…(обрезано по бюджету контекста)")
                remaining = 0
            }
        }
        if !skipped.isEmpty {
            parts.append("(не вошли в бюджет: \(skipped.joined(separator: ", ")) — читай их через read_file)")
        }
        return parts.joined(separator: "\n\n")
    }
}
