// GitTools.swift — встроенные инструменты обзора репозитория (задача 21).
//
// Пять классов, каждый — отдельный BuiltinTool: ветки, статус, история,
// список файлов, чтение файла. Все операции ТОЛЬКО ЧТЕНИЕ — write-операции
// (commit/push из чата) вне объёма (см. BACKLOG п. 16: понадобится confirm).
// Git-инструменты работают через GitClient (задача 16); файловые — через
// SafePath (пути от модели — недоверенный ввод).

import Foundation

// MARK: - git_branches

/// Ветки репозитория: текущая, локальные, remote.
final class GitBranchesTool: BuiltinTool {
    let name = "git_branches"
    let description = "Список веток git-репозитория проекта: текущая, локальные и remote-ветки."
    let parameters = ToolSchemas.empty

    private let git: GitClient
    init(git: GitClient) { self.git = git }

    func execute(_ ctx: ToolContext) async -> ToolResult {
        do {
            let branches = try await git.branches()
            var lines: [String] = []
            lines.append("Текущая ветка: \(branches.current ?? "(detached HEAD или нет коммитов)")")
            if !branches.local.isEmpty {
                lines.append("Локальные: \(branches.local.joined(separator: ", "))")
            }
            if !branches.remote.isEmpty {
                lines.append("Remote: \(branches.remote.joined(separator: ", "))")
            }
            if branches.local.isEmpty && branches.remote.isEmpty {
                lines.append("Веток нет (пустой репозиторий).")
            }
            return .ok(lines.joined(separator: "\n"))
        } catch {
            return .error(Self.describe(error))
        }
    }

    /// Единый текст git-ошибок для модели (LocalizedError → его описание).
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - git_status

/// Статус: ветка, upstream, ahead/behind, изменённые файлы.
final class GitStatusTool: BuiltinTool {
    let name = "git_status"
    let description = "Статус git-репозитория проекта: ветка, upstream, ahead/behind, изменённые файлы."
    let parameters = ToolSchemas.empty

    private let git: GitClient
    init(git: GitClient) { self.git = git }

    func execute(_ ctx: ToolContext) async -> ToolResult {
        do {
            let status = try await git.status()
            var lines: [String] = []
            lines.append("Ветка: \(status.branch ?? "—")")
            if let upstream = status.upstream {
                var line = "Upstream: \(upstream)"
                if status.ahead > 0 || status.behind > 0 {
                    line += " (впереди на \(status.ahead), позади на \(status.behind))"
                }
                lines.append(line)
            }
            if status.isClean {
                lines.append("Рабочее дерево чистое.")
            } else {
                lines.append("Изменения (\(status.changes.count)):")
                for change in status.changes.prefix(100) {
                    lines.append("  \(change.kind.rawValue): \(change.path)")
                }
                if status.changes.count > 100 {
                    lines.append("  …и ещё \(status.changes.count - 100)")
                }
                if !status.conflicted.isEmpty {
                    lines.append("Конфликты: \(status.conflicted.joined(separator: ", "))")
                }
            }
            return .ok(lines.joined(separator: "\n"))
        } catch {
            return .error(GitBranchesTool.describe(error))
        }
    }
}

// MARK: - git_log

/// Последние коммиты.
final class GitLogTool: BuiltinTool {
    /// Верхний предел limit — защита от запроса «покажи всю историю».
    static let maxLimit = 50
    static let defaultLimit = 20

    let name = "git_log"
    let description = "Последние коммиты git-репозитория проекта (хеш, дата, автор, тема)."
    let parameters = ToolSchemas.object([
        "limit": ToolSchemas.integer("Сколько коммитов показать (1–\(GitLogTool.maxLimit), по умолчанию \(GitLogTool.defaultLimit)).")
    ])

    private let git: GitClient
    init(git: GitClient) { self.git = git }

    func execute(_ ctx: ToolContext) async -> ToolResult {
        let limit = min(max(ctx.intInput("limit") ?? Self.defaultLimit, 1), Self.maxLimit)
        do {
            let commits = try await git.log(limit: limit)
            guard !commits.isEmpty else { return .ok("Коммитов нет (пустой репозиторий).") }
            let formatter = ISO8601DateFormatter()
            let lines = commits.map { commit in
                "\(commit.shortHash) \(formatter.string(from: commit.date)) \(commit.author): \(commit.subject)"
            }
            return .ok(lines.joined(separator: "\n"))
        } catch {
            return .error(GitBranchesTool.describe(error))
        }
    }
}

// MARK: - git_diff

/// Diff незакоммиченных изменений (задача 25, «по желанию — diff» из
/// исходной задачи пользователя). Только чтение.
final class GitDiffTool: BuiltinTool {
    /// Кап вывода — диффы бывают огромными, модели столько не нужно.
    static let maxChars = 64 * 1024

    let name = "git_diff"
    let description = "Diff незакоммиченных изменений репозитория проекта (рабочее дерево против HEAD). Опционально — только по указанному пути."
    let parameters = ToolSchemas.object([
        "path": ToolSchemas.string("Файл или папка относительно корня; пусто — весь репозиторий.")
    ])

    private let git: GitClient
    init(git: GitClient) { self.git = git }

    func execute(_ ctx: ToolContext) async -> ToolResult {
        var path: String?
        if let p = ctx.input("path"), !p.isEmpty {
            guard SafePath.resolve(p, under: ctx.repoRoot) != nil else {
                return .error("путь «\(p)» вне корня проекта")
            }
            path = p
        }
        do {
            let out = try await git.diff(path: path)
            guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .ok("Незакоммиченных изменений нет.")
            }
            if out.count > Self.maxChars {
                return .ok(String(out.prefix(Self.maxChars)) + "\n…(diff обрезан, уточните path)")
            }
            return .ok(out)
        } catch {
            return .error(GitBranchesTool.describe(error))
        }
    }
}

// MARK: - list_files

/// Список файлов: git ls-files, фолбэк — обход ФС (папка без git).
final class ListFilesTool: BuiltinTool {
    /// Кап на размер списка — модели не нужен многотысячный вывод целиком.
    static let maxEntries = 2000
    /// Папки, мусорные для обзора проекта (только для ФС-фолбэка: git сам
    /// не отдаёт неотслеживаемое).
    private static let skippedDirectories: Set<String> = [".git", ".build", "node_modules"]

    let name = "list_files"
    let description = "Список файлов проекта (отслеживаемые git; без git — обход папки). Опционально — фильтр по подпапке."
    let parameters = ToolSchemas.object([
        "path": ToolSchemas.string("Подпапка относительно корня; пусто — весь проект.")
    ])

    private let git: GitClient
    init(git: GitClient) { self.git = git }

    func execute(_ ctx: ToolContext) async -> ToolResult {
        // Фильтр-подпапка проверяется как недоверенный путь.
        var prefix = ""
        if let path = ctx.input("path"), !path.isEmpty {
            guard SafePath.resolve(path, under: ctx.repoRoot) != nil else {
                return .error("путь «\(path)» вне корня проекта")
            }
            prefix = path.hasSuffix("/") ? path : path + "/"
        }

        var files = (try? await git.trackedFiles()) ?? []
        if files.isEmpty {
            files = Self.walkFileSystem(root: ctx.repoRoot)
        }
        if !prefix.isEmpty {
            files = files.filter { $0.hasPrefix(prefix) }
        }
        guard !files.isEmpty else {
            return .ok(prefix.isEmpty ? "Файлов нет." : "В «\(prefix)» файлов нет.")
        }
        var lines = Array(files.prefix(Self.maxEntries))
        if files.count > Self.maxEntries {
            lines.append("…и ещё \(files.count - Self.maxEntries) (уточните подпапку через path)")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    /// Обход ФС для папки без git: пропускаем скрытое и служебные каталоги.
    /// Не private: search_files (задача 39) обходит файлы тем же способом.
    static func walkFileSystem(root: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var result: [String] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if skippedDirectories.contains(name) { enumerator.skipDescendants() }
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            result.append(String(path.dropFirst(rootPath.count + 1)))
            // Кап с запасом: дальше всё равно обрежем, а обход дорогой.
            if result.count > maxEntries * 2 { break }
        }
        return result.sorted()
    }
}

// MARK: - read_file

/// Чтение текстового файла проекта (только чтение, с капом размера).
final class ReadFileTool: BuiltinTool {
    /// Жёсткий кап чтения: больше модели за раз не нужно.
    static let hardMaxBytes = 64 * 1024

    let name = "read_file"
    let description = "Прочитать текстовый файл проекта по относительному пути (только чтение, до 64 КБ)."
    let parameters = ToolSchemas.object([
        "path": ToolSchemas.string("Путь к файлу относительно корня проекта."),
        "maxBytes": ToolSchemas.integer("Максимум байт (по умолчанию и не более \(ReadFileTool.hardMaxBytes)).")
    ], required: ["path"])

    func execute(_ ctx: ToolContext) async -> ToolResult {
        guard let path = ctx.input("path"), !path.isEmpty else {
            return .error("не указан аргумент path")
        }
        guard let url = SafePath.resolve(path, under: ctx.repoRoot) else {
            return .error("путь «\(path)» вне корня проекта или некорректен")
        }
        var isDirectory: ObjCBool = false
        var target = url
        var readPath = path
        if !FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            // Заметки — .md; модель и пользователь часто опускают расширение
            // («заметка Отчёт-анализа»). Пробуем «<path>.md», прежде чем сдаться.
            if !path.lowercased().hasSuffix(".md"),
               let mdURL = SafePath.resolve(path + ".md", under: ctx.repoRoot),
               FileManager.default.fileExists(atPath: mdURL.path, isDirectory: &isDirectory) {
                target = mdURL
                readPath = path + ".md"
            } else {
                return .error("файл «\(path)» не найден")
            }
        }
        guard !isDirectory.boolValue else {
            return .error("«\(path)» — папка; используйте list_files")
        }

        let cap = min(max(ctx.intInput("maxBytes") ?? Self.hardMaxBytes, 1), Self.hardMaxBytes)
        guard let handle = try? FileHandle(forReadingFrom: target) else {
            return .error("не удалось открыть «\(path)»")
        }
        defer { try? handle.close() }
        // Читаем на байт больше капа — чтобы отличить «ровно cap» от обрезки.
        guard let data = try? handle.read(upToCount: cap + 1) else {
            return .error("не удалось прочитать «\(path)»")
        }
        let truncated = data.count > cap
        let payload = truncated ? data.prefix(cap) : data
        // NUL-байт — надёжный признак бинарника; текстовые файлы его не содержат.
        guard !payload.contains(0) else {
            return .error("«\(path)» — бинарный файл, чтение не поддерживается")
        }
        guard var text = String(data: payload, encoding: .utf8) else {
            return .error("«\(path)» не в кодировке UTF-8")
        }
        if truncated {
            text += "\n…(файл обрезан до \(cap) байт)"
        } else {
            // Полное чтение регистрируется в контексте чата (задача 39):
            // mtime-guard разрешит последующую перезапись write_file/edit_file.
            // Обрезанное чтение НЕ регистрируется — модель видела не весь файл.
            await ctx.fileOps?.noteRead(path: readPath,
                                        mtime: FileToolSupport.modificationDate(of: target))
        }
        return .ok(text)
    }
}
