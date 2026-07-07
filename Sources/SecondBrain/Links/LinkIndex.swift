// LinkIndex.swift — индекс связей vault: «кто на кого ссылается» + резолв имён.
//
// Устройство:
//  - полный обход .md-файлов при открытии vault (build, off-main);
//  - инкрементальный refresh() по FSEvents-тику: пересканируются только файлы
//    с изменившимся mtime, удалённые выбрасываются;
//  - резолв цели Obsidian-совместимый: по имени файла без расширения,
//    регистронезависимо; при дублях побеждает кратчайший путь; цель с «/»
//    резолвится как относительный путь от корня vault.
//
// Производные данные (инвариант №1): индекс всегда пересоздаваем из vault,
// на диск не пишется. Прицел на задачу 19 (переименование с обновлением
// ссылок): у каждой ссылки хранится точный диапазон в исходном файле.

import Foundation

/// Вхождение ссылки: где стоит и на что указывает.
struct LinkOccurrence: Equatable {
    /// Файл-источник (в нём написана [[ссылка]]).
    let sourceFile: URL
    let link: Wikilink
    /// Строка исходника со ссылкой — сниппет для панели backlinks.
    let snippet: String
    /// Номер строки (с 1) — пригодится переходу к месту ссылки.
    let lineNumber: Int
}

/// Индекс связей. Не @MainActor: build зовётся с фоновой очереди,
/// дальнейшие мутации (refresh/updateFile) — только с main (владелец — VaultManager).
final class LinkIndex {

    let root: URL

    /// Исходящие ссылки по файлам: путь → вхождения.
    private(set) var outgoing: [String: [LinkOccurrence]] = [:]
    /// Имя файла без расширения (lowercased) → файлы с таким именем.
    private var nameTable: [String: [URL]] = [:]
    /// Относительный путь без расширения (lowercased) → файл.
    private var pathTable: [String: URL] = [:]
    /// mtime файлов на момент индексации — для инкрементального refresh.
    private var fileMTimes: [String: Date] = [:]

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    // MARK: - Построение

    /// Полное построение с нуля. Синхронное — зовите с фоновой очереди
    /// (VaultManager делает это через Task.detached).
    func buildFull() {
        outgoing = [:]
        nameTable = [:]
        pathTable = [:]
        fileMTimes = [:]
        for url in markdownFiles() {
            indexFile(url)
        }
    }

    /// Инкрементальное обновление: новые/изменённые файлы переиндексируются,
    /// пропавшие выбрасываются. Возвращает true, если что-то поменялось.
    @discardableResult
    func refresh() -> Bool {
        var changed = false
        var seen = Set<String>()

        for url in markdownFiles() {
            let path = url.path
            seen.insert(path)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if fileMTimes[path] != mtime {
                removeFile(path)
                indexFile(url)
                changed = true
            }
        }
        for path in fileMTimes.keys where !seen.contains(path) {
            removeFile(path)
            changed = true
        }
        return changed
    }

    /// Переиндексация одного файла (например, после сохранения в редакторе).
    func updateFile(_ url: URL) {
        removeFile(url.standardizedFileURL.path)
        if FileManager.default.fileExists(atPath: url.path) {
            indexFile(url.standardizedFileURL)
        }
    }

    // MARK: - Запросы

    /// Резолв цели ссылки в файл. Правила Obsidian: цель с «/» — по пути от
    /// корня; иначе по имени; регистр не важен; при дублях — кратчайший путь.
    func resolve(_ target: String) -> URL? {
        let cleaned = target.trimmingCharacters(in: .whitespaces).lowercased()
        guard !cleaned.isEmpty else { return nil }
        if cleaned.contains("/") {
            return pathTable[cleaned]
        }
        guard let candidates = nameTable[cleaned], !candidates.isEmpty else { return nil }
        return candidates.min { a, b in
            let ca = a.pathComponents.count, cb = b.pathComponents.count
            if ca != cb { return ca < cb }
            return a.path < b.path // при равной глубине — детерминированно
        }
    }

    /// Обратные ссылки: все вхождения по vault, целящие в этот файл.
    func backlinks(to url: URL) -> [LinkOccurrence] {
        let targetPath = url.standardizedFileURL.path
        var result: [LinkOccurrence] = []
        for occurrences in outgoing.values {
            for occurrence in occurrences
            where occurrence.sourceFile.path != targetPath
                && resolve(occurrence.link.target)?.path == targetPath {
                result.append(occurrence)
            }
        }
        return result.sorted {
            ($0.sourceFile.path, $0.lineNumber) < ($1.sourceFile.path, $1.lineNumber)
        }
    }

    /// Цели для автокомплита: уникальные имена; для дублей — относительные
    /// пути, чтобы ссылка была однозначной.
    var completionTargets: [String] {
        var targets: [String] = []
        for (_, urls) in nameTable {
            if urls.count == 1, let url = urls.first {
                targets.append(url.deletingPathExtension().lastPathComponent)
            } else {
                targets.append(contentsOf: urls.map { relativePathNoExtension(of: $0) })
            }
        }
        return targets.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Внутреннее

    private func markdownFiles() -> [URL] {
        VaultScanner.markdownFiles(in: root) // общий обход всех индексов (задача 05)
    }

    private func indexFile(_ url: URL) {
        let path = url.path
        fileMTimes[path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        nameTable[name, default: []].append(url)
        pathTable[relativePathNoExtension(of: url).lowercased()] = url

        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let links = WikilinkParser.parse(text)
        guard !links.isEmpty else { return }

        // Границы строк для сниппетов и номеров строк (UTF-16, как NSRange ссылок).
        let ns = text as NSString
        var occurrences: [LinkOccurrence] = []
        for link in links {
            let lineRange = ns.lineRange(for: NSRange(location: link.range.location, length: 0))
            let snippet = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let lineNumber = ns.substring(to: link.range.location).components(separatedBy: "\n").count
            occurrences.append(LinkOccurrence(
                sourceFile: url,
                link: link,
                snippet: snippet,
                lineNumber: lineNumber
            ))
        }
        outgoing[path] = occurrences
    }

    private func removeFile(_ path: String) {
        outgoing[path] = nil
        fileMTimes[path] = nil
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        nameTable[name]?.removeAll { $0.path == path }
        if nameTable[name]?.isEmpty == true { nameTable[name] = nil }
        pathTable[relativePathNoExtension(of: url).lowercased()] = nil
    }

    private func relativePathNoExtension(of url: URL) -> String {
        let filePath = url.deletingPathExtension().path
        let rootPath = root.path + "/"
        return filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count)) : filePath
    }
}

/// Fuzzy-фильтр для автокомплита wikilinks: сначала префиксные совпадения,
/// затем вхождения подстроки, затем подпоследовательности. Регистр не важен.
enum FuzzyMatch {

    static func filter(_ query: String, candidates: [String]) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return candidates }

        // (кандидат, ранг): 0 — префикс, 1 — подстрока, 2 — подпоследовательность.
        var ranked: [(String, Int)] = []
        for candidate in candidates {
            let lower = candidate.lowercased()
            if lower.hasPrefix(q) {
                ranked.append((candidate, 0))
            } else if lower.contains(q) {
                ranked.append((candidate, 1))
            } else if isSubsequence(q, of: lower) {
                ranked.append((candidate, 2))
            }
        }
        return ranked
            .sorted { ($0.1, $0.0.count, $0.0) < ($1.1, $1.0.count, $1.0) }
            .map(\.0)
    }

    /// «фна» найдёт «Финансы и активы»: буквы запроса идут по порядку.
    private static func isSubsequence(_ query: String, of string: String) -> Bool {
        var iterator = string.makeIterator()
        for char in query {
            var found = false
            while let next = iterator.next() {
                if next == char { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}
