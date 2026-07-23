// WikilinkRename.swift — перезапись [[ссылок]] при переименовании заметки (задача 52).
//
// Здесь живут:
//  - WikilinkRenamer — чистое ядро: по тексту заметки и множеству целей,
//    которые надо переписать, возвращает новый текст и число замен;
//  - LinkRenameApplier — тонкий оркестратор: перечитывает файлы-источники
//    свежими с диска, зовёт ядро, пишет назад атомарно.
//
// Поток данных: VaultManager.rename собирает backlinks(to: oldURL) ДО
// переименования → LinkRenameApplier группирует по файлу-источнику →
// на каждый файл WikilinkRenamer.rewrite → атомарная запись назад.
//
// Важно: ядро НЕ использует диапазоны из индекса (они могли устареть с момента
// индексации — файл мог поменяться) — оно заново парсит свежий текст
// WikilinkParser'ом и переписывает только ссылки, чья цель входит в переданное
// множество. Из индекса берётся лишь само множество целей: там резолв
// Obsidian-совместимый (см. LinkIndex.resolve), поэтому коллизии имён
// («[[Имя]]» из разных папок) разрешаются правильно.

import Foundation

/// Чистое ядро перезаписи wikilinks. Статические функции без состояния и I/O.
enum WikilinkRenamer {

    /// Результат перезаписи одного файла.
    struct Rewrite: Equatable {
        /// Новый текст (равен исходному, если заменять было нечего).
        let content: String
        /// Сколько ссылок переписано.
        let replacements: Int
    }

    /// Переписывает в тексте все wikilinks, чья цель (без учёта регистра и
    /// внешних пробелов) входит в `targets`, заменяя базовое имя цели на
    /// `newName`. Путь-префикс «папка/», `#заголовок` и `|алиас` сохраняются
    /// как есть. Ссылки внутри код-блоков не трогаются (их не видит парсер).
    static func rewrite(content: String, targets: Set<String>, to newName: String) -> Rewrite {
        guard !targets.isEmpty else { return Rewrite(content: content, replacements: 0) }
        let links = WikilinkParser.parse(content)
        guard !links.isEmpty else { return Rewrite(content: content, replacements: 0) }

        let ns = NSMutableString(string: content)
        var replacements = 0
        // Справа налево: замена не сдвигает диапазоны ссылок левее неё.
        for link in links.sorted(by: { $0.range.location > $1.range.location }) {
            let key = link.target.trimmingCharacters(in: .whitespaces).lowercased()
            guard targets.contains(key) else { continue }
            guard let rewritten = rewrittenLinkText(ns.substring(with: link.range), to: newName) else { continue }
            ns.replaceCharacters(in: link.range, with: rewritten)
            replacements += 1
        }
        return Rewrite(content: ns as String, replacements: replacements)
    }

    // MARK: - Внутреннее

    /// По полной подстроке `[[...]]` возвращает её же с заменённым базовым именем
    /// цели. nil — если это не похоже на `[[...]]` (защита: не должно случиться
    /// для подстроки, которую вернул WikilinkParser).
    private static func rewrittenLinkText(_ linkText: String, to newName: String) -> String? {
        guard linkText.hasPrefix("[["), linkText.hasSuffix("]]"), linkText.count >= 4 else { return nil }
        let inner = String(linkText.dropFirst(2).dropLast(2))

        // Граница цели — первый из символов «#» (заголовок) или «|» (алиас):
        // цель всегда идёт первой, что бы ни шло после.
        let boundary = inner.firstIndex { $0 == "#" || $0 == "|" } ?? inner.endIndex
        let targetRegion = String(inner[..<boundary])   // возможно с внешними пробелами
        let rest = String(inner[boundary...])           // «#…», «|…» или «»

        return "[[" + replacingBasename(in: targetRegion, with: newName) + rest + "]]"
    }

    /// В строке цели (возможно «папка/Имя» и с внешними пробелами) заменяет
    /// последний компонент пути на `newName`, сохраняя пробелы и путь-префикс.
    private static func replacingBasename(in targetRegion: String, with newName: String) -> String {
        let trimmed = targetRegion.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let range = targetRegion.range(of: trimmed) else { return targetRegion }
        let leading = String(targetRegion[..<range.lowerBound])
        let trailing = String(targetRegion[range.upperBound...])

        if let slash = trimmed.lastIndex(of: "/") {
            let prefix = String(trimmed[...slash])       // включая сам «/»
            return leading + prefix + newName + trailing
        }
        return leading + newName + trailing
    }
}

/// Оркестратор I/O: применяет переименование к файлам-источникам ссылок.
/// Отдельно от ядра — здесь чтение/запись диска, ядро остаётся чистым.
enum LinkRenameApplier {

    /// Перечитывает каждый файл-источник свежим, переписывает в нём ссылки на
    /// переименованную заметку и пишет назад атомарно.
    ///
    /// - Parameters:
    ///   - backlinks: вхождения ссылок на старый URL, собранные ДО
    ///     переименования (их цели уже резолвятся в переименованную заметку);
    ///   - newName: новое базовое имя заметки (без расширения).
    /// - Returns: имена файлов, которые не удалось перечитать или записать
    ///   (пусто — всё прошло). Вызывающий доводит до пользователя.
    @discardableResult
    static func apply(backlinks: [LinkOccurrence], to newName: String) -> [String] {
        guard !backlinks.isEmpty else { return [] }

        // Множество целевых строк для перезаписи — резолв уже сделан в backlinks.
        let targets = Set(backlinks.map { $0.link.target.trimmingCharacters(in: .whitespaces).lowercased() })
        // Каждый файл трогаем один раз, а не на каждую ссылку в нём.
        let files = Set(backlinks.map { $0.sourceFile.standardizedFileURL })

        var failures: [String] = []
        for url in files {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                failures.append(url.lastPathComponent)
                continue
            }
            let result = WikilinkRenamer.rewrite(content: content, targets: targets, to: newName)
            guard result.replacements > 0, result.content != content else { continue }
            do {
                try Data(result.content.utf8).write(to: url, options: .atomic)
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        return failures.sorted()
    }
}
