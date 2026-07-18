// UnifiedDiff.swift — построчный unified diff без git (задача 39).
//
// GitDiffTool показывает только незакоммиченные изменения git-репозитория;
// файловым инструментам нужен diff для ЛЮБОЙ папки (vault, не-git каталог)
// и для новых файлов — поэтому своя чистая реализация: LCS по строкам с
// обрезкой общих префикса/суффикса, hunks с контекстом 3, формат совместим
// с привычным `diff -u` (--- a/… / +++ b/… / @@).
//
// Отсутствие завершающего перевода строки кодируется сентинелом в последней
// строке при сравнении и разворачивается в стандартную пометку
// «\ No newline at end of file» при выводе.

import Foundation

enum UnifiedDiff {
    /// Строк контекста вокруг изменений (как у diff -u по умолчанию).
    static let contextLines = 3
    /// Кап на размер файла в строках: больше — честный фолбэк без LCS.
    static let maxLines = 10_000
    /// Кап на произведение размеров середины (память DP-таблицы LCS).
    static let maxLCSProduct = 4_000_000

    /// Сентинел «нет \n в конце файла»: приклеивается к последней строке,
    /// чтобы "a\nb" и "a\nb\n" не считались равными при сравнении строк.
    private static let noNewlineSentinel = "\u{0}"
    private static let noNewlineMark = "\\ No newline at end of file"

    /// Итог diff'а: текст + счётчики для короткого отчёта модели.
    struct Result: Equatable {
        var text: String
        var added: Int
        var removed: Int

        var isEmpty: Bool { added == 0 && removed == 0 }
        /// «+3/−1 строк» — суффикс ответа write-инструментов.
        var summary: String { "+\(added)/−\(removed) строк" }
    }

    /// Diff старого содержимого против нового. old nil — новый файл
    /// (заголовок /dev/null); new nil — удаление файла.
    static func make(path: String, old: String?, new: String?) -> Result {
        let oldLines = old.map(splitLines) ?? []
        let newLines = new.map(splitLines) ?? []

        // Фолбэк для гигантских файлов: LCS не считаем, отчёт честный.
        guard oldLines.count <= maxLines, newLines.count <= maxLines else {
            return Result(text: "(файл заменён целиком: \(oldLines.count) → \(newLines.count) строк)",
                          added: newLines.count, removed: oldLines.count)
        }

        // Общие префикс и суффикс — вне DP-таблицы (типичная правка меняет
        // несколько строк в большом файле).
        var prefix = 0
        while prefix < oldLines.count && prefix < newLines.count
                && oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix && suffix < newLines.count - prefix
                && oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }
        let oldMid = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let newMid = Array(newLines[prefix..<(newLines.count - suffix)])

        guard oldMid.count * newMid.count <= maxLCSProduct else {
            return Result(text: "(файл заменён целиком: \(oldLines.count) → \(newLines.count) строк)",
                          added: newLines.count, removed: oldLines.count)
        }

        // Операции середины + равные хвосты → полный список операций.
        var ops: [Op] = Array(repeating: .equal, count: prefix)
        ops += diffOps(oldMid, newMid)
        ops += Array(repeating: .equal, count: suffix)

        let added = ops.filter { $0 == .insert }.count
        let removed = ops.filter { $0 == .delete }.count
        guard added > 0 || removed > 0 else {
            return Result(text: "", added: 0, removed: 0)
        }

        let header = (old == nil ? "--- /dev/null" : "--- a/\(path)") + "\n"
            + (new == nil ? "+++ /dev/null" : "+++ b/\(path)")
        let body = renderHunks(ops: ops, oldLines: oldLines, newLines: newLines)
        return Result(text: header + "\n" + body, added: added, removed: removed)
    }

    // MARK: - Внутренности

    /// Операция над очередной строкой (в порядке обхода old/new).
    private enum Op { case equal, delete, insert }

    /// Разбивка на строки с кодированием завершающего \n: у файла без
    /// перевода строки в конце последняя строка получает сентинел.
    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        } else {
            lines[lines.count - 1] += noNewlineSentinel
        }
        return lines
    }

    /// Классический DP-LCS по середине (префикс/суффикс уже отрезаны).
    /// Возвращает операции в порядке следования строк.
    private static func diffOps(_ old: [String], _ new: [String]) -> [Op] {
        let m = old.count, n = new.count
        if m == 0 { return Array(repeating: .insert, count: n) }
        if n == 0 { return Array(repeating: .delete, count: m) }

        // Таблица длин LCS (m+1)×(n+1); UInt32 экономит память на капе.
        var table = [UInt32](repeating: 0, count: (m + 1) * (n + 1))
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                let idx = i * (n + 1) + j
                if old[i] == new[j] {
                    table[idx] = table[(i + 1) * (n + 1) + j + 1] + 1
                } else {
                    table[idx] = max(table[(i + 1) * (n + 1) + j], table[idx + n + 1])
                }
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < m && j < n {
            if old[i] == new[j] {
                ops.append(.equal); i += 1; j += 1
            } else if table[(i + 1) * (n + 1) + j] >= table[i * (n + 1) + j + 1] {
                ops.append(.delete); i += 1
            } else {
                ops.append(.insert); j += 1
            }
        }
        ops += Array(repeating: .delete, count: m - i)
        ops += Array(repeating: .insert, count: n - j)
        return ops
    }

    /// Сборка hunks с контекстом: соседние изменения (разрыв ≤ 2×context)
    /// объединяются в один hunk — как делает diff -u.
    private static func renderHunks(ops: [Op], oldLines: [String], newLines: [String]) -> String {
        // Индексы операций-изменений.
        let changed = ops.indices.filter { ops[$0] != .equal }
        guard !changed.isEmpty else { return "" }

        // Группировка изменений в hunks по разрыву между ними.
        var groups: [(from: Int, to: Int)] = []
        var start = changed[0], previous = changed[0]
        for index in changed.dropFirst() {
            if index - previous > contextLines * 2 {
                groups.append((start, previous))
                start = index
            }
            previous = index
        }
        groups.append((start, previous))

        // Позиции строк old/new перед каждой операцией — для заголовков @@.
        var oldPos = [Int](repeating: 0, count: ops.count + 1)
        var newPos = [Int](repeating: 0, count: ops.count + 1)
        for (index, op) in ops.enumerated() {
            oldPos[index + 1] = oldPos[index] + (op == .insert ? 0 : 1)
            newPos[index + 1] = newPos[index] + (op == .delete ? 0 : 1)
        }

        var out: [String] = []
        for group in groups {
            let from = max(0, group.from - contextLines)
            let to = min(ops.count - 1, group.to + contextLines)
            let oldStart = oldPos[from], newStart = newPos[from]
            let oldCount = oldPos[to + 1] - oldStart
            let newCount = newPos[to + 1] - newStart
            // Нумерация 1-based; пустая сторона — «0,0» (как у diff).
            out.append("@@ -\(oldCount == 0 ? 0 : oldStart + 1),\(oldCount) +\(newCount == 0 ? 0 : newStart + 1),\(newCount) @@")
            var oi = oldStart, ni = newStart
            for index in from...to {
                switch ops[index] {
                case .equal:
                    out.append(contentsOf: renderLine(" ", oldLines[oi]))
                    oi += 1; ni += 1
                case .delete:
                    out.append(contentsOf: renderLine("-", oldLines[oi]))
                    oi += 1
                case .insert:
                    out.append(contentsOf: renderLine("+", newLines[ni]))
                    ni += 1
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// Строка diff'а; сентинел «нет \n» разворачивается в стандартную пометку.
    private static func renderLine(_ prefix: String, _ line: String) -> [String] {
        guard line.hasSuffix(noNewlineSentinel) else { return [prefix + line] }
        return [prefix + String(line.dropLast()), noNewlineMark]
    }
}
