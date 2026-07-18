// ChatChangesModels.swift — чистая логика вкладки «Изменения» (задача 40).
//
// Вкладка показывает две картины:
//  1) что агент менял В ЭТОМ ЧАТЕ — агрегат fileChanges по сообщениям;
//  2) что сейчас изменено в git-каталоге чата — незакоммиченный diff
//     (рабочее дерево против HEAD) и, если ветка не main/master, — отличия
//     ветки от базовой (main…HEAD).
// Здесь НЕТ SwiftUI: разбиение diff'а по файлам, агрегация изменений чата и
// загрузчик git-обзора — чистые/изолированные и покрыты тестами.

import Foundation

// MARK: - Разбиение unified diff по файлам

/// Секция diff'а одного файла — карточка во вкладке «Изменения».
struct DiffFileSection: Identifiable, Equatable {
    var path: String
    /// Полный текст секции (заголовки --- / +++ и hunks).
    var text: String
    var added: Int
    var removed: Int

    var id: String { path }
    /// «+12 −3» для бейджа карточки.
    var badge: String { "+\(added) −\(removed)" }
}

/// Разбивает вывод `git diff` на секции по файлам (маркер «diff --git»).
enum DiffSplitter {
    static func split(_ unifiedDiff: String) -> [DiffFileSection] {
        let trimmed = unifiedDiff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var sections: [DiffFileSection] = []
        var currentPath: String?
        var currentLines: [String] = []

        func flush() {
            guard let path = currentPath, !currentLines.isEmpty else { return }
            let body = currentLines.joined(separator: "\n")
            sections.append(DiffFileSection(path: path, text: body,
                                            added: count(body, prefix: "+"),
                                            removed: count(body, prefix: "-")))
        }

        for line in trimmed.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = parsePath(fromHeader: line)
                currentLines = [line]
            } else if currentPath != nil {
                currentLines.append(line)
            } else {
                // Diff без заголовка «diff --git» (наш UnifiedDiff) — одна секция.
                currentPath = parsePath(fromUnified: trimmed) ?? "(файл)"
                currentLines = [line]
            }
        }
        flush()
        return sections
    }

    /// Счёт добавленных/удалённых строк: «+»/«-», но не заголовки «+++»/«---».
    private static func count(_ body: String, prefix: String) -> Int {
        body.components(separatedBy: "\n").filter {
            $0.hasPrefix(prefix) && !$0.hasPrefix(prefix + prefix + prefix)
        }.count
    }

    /// «diff --git a/path b/path» → path (сторона b — итоговое имя).
    private static func parsePath(fromHeader line: String) -> String {
        if let range = line.range(of: " b/") {
            return String(line[range.upperBound...])
        }
        return line.replacingOccurrences(of: "diff --git ", with: "")
    }

    /// Для diff'а без «diff --git»: путь из «+++ b/path» либо «--- a/path».
    private static func parsePath(fromUnified text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("+++ b/") { return String(line.dropFirst(6)) }
            if line.hasPrefix("--- a/") { return String(line.dropFirst(6)) }
        }
        return nil
    }
}

// MARK: - Агрегация изменений агента по чату

/// Одна запись «агент изменил файл» с привязкой к сообщению.
struct AgentChangeEntry: Identifiable, Equatable {
    let change: FileChangeDisplay
    let messageDate: Date
    var id: UUID { change.id }
}

enum ChatChangesAggregator {
    /// Все файловые операции агента в чате, новые сверху.
    static func agentChanges(messages: [ChatMessage]) -> [AgentChangeEntry] {
        var entries: [AgentChangeEntry] = []
        for message in messages {
            for change in message.fileChanges ?? [] {
                entries.append(AgentChangeEntry(change: change,
                                                messageDate: message.createdAt))
            }
        }
        return entries.reversed()
    }
}

// MARK: - Git-обзор каталога чата

/// Снимок git-состояния рабочего каталога для вкладки «Изменения».
struct GitChangesOverview: Equatable {
    /// Каталог вообще является git-репозиторием.
    var isRepo = false
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    /// Изменённые файлы (status): staged + unstaged + untracked.
    var files: [GitFileChange] = []
    /// Незакоммиченный diff (рабочее дерево против HEAD), кап maxDiffChars.
    var diff = ""
    /// Базовая ветка (main/master), если текущая — другая; для секции
    /// «Отличия ветки от базы».
    var baseBranch: String?
    /// diff base...HEAD (закоммиченные отличия ветки от базы).
    var baseDiff = ""

    /// Кап diff'а: больше во вкладке всё равно не читается.
    static let maxDiffChars = 256 * 1024

    var isClean: Bool { files.isEmpty && diff.isEmpty }

    /// Загрузка обзора. Изолирована от AppModel — тестируется на temp-репо.
    static func load(git: GitClient) async -> GitChangesOverview {
        guard await git.isRepository() else { return GitChangesOverview() }
        var overview = GitChangesOverview(isRepo: true)
        if let status = try? await git.status() {
            overview.branch = status.branch
            overview.upstream = status.upstream
            overview.ahead = status.ahead
            overview.behind = status.behind
            overview.files = status.changes
        }
        overview.diff = cap((try? await git.diff()) ?? "")
        // Отличия ветки от базы: только когда стоим НЕ на main/master.
        if let branches = try? await git.branches(), let current = branches.current {
            for base in ["main", "master"]
            where base != current && branches.local.contains(base) {
                overview.baseBranch = base
                overview.baseDiff = cap((try? await git.raw(["diff", "\(base)...HEAD"],
                                                            timeout: 60)) ?? "")
                break
            }
        }
        return overview
    }

    private static func cap(_ text: String) -> String {
        text.count > maxDiffChars
            ? String(text.prefix(maxDiffChars)) + "\n…(diff обрезан)"
            : text
    }
}

// MARK: - Точечный откат файла

/// Откат ОДНОГО файла (задача 40, по фидбеку «агент хотел откатить лишнее»):
/// tracked-файл возвращается к HEAD (git checkout HEAD -- path), новый
/// (untracked) — перемещается в Корзину (обратимо; git clean не используем
/// принципиально). Массовых откатов здесь нет — только по одному пути.
enum GitRevert {
    /// nil — успех; иначе текст ошибки для баннера.
    static func revert(git: GitClient, root: URL, path: String) async -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "пустой путь" }
        // Путь из git status/чата — всё равно прогоняем через SafePath:
        // откат не должен уметь выйти из корня каталога.
        guard let url = SafePath.resolve(trimmed, under: root) else {
            return "путь «\(trimmed)» вне корня каталога"
        }
        let tracked = (try? await git.raw(["ls-files", "--", trimmed], timeout: 15))?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if tracked {
            do {
                _ = try await git.raw(["checkout", "HEAD", "--", trimmed], timeout: 30)
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "«\(trimmed)» не найден (уже откачен?)"
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return nil
        } catch {
            return "не удалось переместить «\(trimmed)» в Корзину: \(error.localizedDescription)"
        }
    }
}
