// NoteRenamePlanner.swift — чистое ядро переименования заметки: какие ссылки
// в каких файлах поменять и на какой текст. Файловый I/O (чтение, атомарная
// запись, сам rename) — в VaultManager.rename; здесь только вычисление правок
// по уже готовому списку backlinks из LinkIndex.
//
// range в LinkRewrite закэширован в LinkIndex на момент индексации — файл к
// моменту применения (перечитанный заново) мог измениться (автосохранение
// редактора, внешняя правка, git-синк), и диапазон может указывать не туда.
// apply() поэтому сверяет каждое вхождение со свежим текстом (expectedTarget)
// перед replaceCharacters и молча пропускает несовпавшие — некорректный
// NSRange у NSMutableString это NSInvalidArgumentException/abort(), не
// Swift Error, try/catch его не ловит.

import Foundation

/// Одна правка: диапазон `[[...]]` в исходном тексте файла → новый текст ссылки.
struct LinkRewrite: Equatable {
    let sourceFile: URL
    let range: NSRange
    let replacement: String
    /// Цель ссылки на момент индексации — по ней сверяется свежий текст.
    let expectedTarget: String
}

enum NoteRenamePlanner {

    /// Правки для всех вхождений backlinks: цель ссылки меняется на `newName`
    /// (без расширения), заголовок секции и алиас — сохраняются как есть.
    /// Ссылка с путём («Папка/Старое имя») сохраняет путь, меняется только
    /// последний компонент — переименование папок вне объёма.
    static func rewrites(for backlinks: [LinkOccurrence], newName: String) -> [LinkRewrite] {
        backlinks.map { occurrence in
            LinkRewrite(
                sourceFile: occurrence.sourceFile,
                range: occurrence.link.range,
                replacement: rewrittenLinkText(for: occurrence.link, newName: newName),
                expectedTarget: occurrence.link.target
            )
        }
    }

    /// Применяет правки одного файла к СВЕЖЕМУ тексту (перечитанному непосредственно
    /// перед записью). Валидные вхождения применяются от конца к началу, иначе более
    /// ранняя правка сдвинет смещения последующих; устаревшие (см. заголовок файла)
    /// пропускаются поодиночке — остальные валидные правки в этом же файле применяются.
    static func apply(_ rewrites: [LinkRewrite], to text: String) -> String {
        let ns = NSMutableString(string: text)
        for rewrite in rewrites.sorted(by: { $0.range.location > $1.range.location })
        where isStillValid(rewrite, in: ns) {
            ns.replaceCharacters(in: rewrite.range, with: rewrite.replacement)
        }
        return ns as String
    }

    /// Диапазон реально указывает на ожидаемую wikilink в свежем тексте: в
    /// границах строки, начинается с «[[» и содержит цель, записанную при
    /// индексации. Не идеальная защита (текст мог поменяться так, что случайно
    /// совпадёт), но отсекает подавляющее большинство сдвигов и падений.
    static func isStillValid(_ rewrite: LinkRewrite, in ns: NSString) -> Bool {
        let range = rewrite.range
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= ns.length else { return false }
        let substring = ns.substring(with: range)
        return substring.hasPrefix("[[") && substring.contains(rewrite.expectedTarget)
    }

    private static func rewrittenLinkText(for link: Wikilink, newName: String) -> String {
        var inner = renamedTarget(link.target, newName: newName)
        if let heading = link.heading { inner += "#\(heading)" }
        if let alias = link.alias { inner += "|\(alias)" }
        return "[[\(inner)]]"
    }

    private static func renamedTarget(_ target: String, newName: String) -> String {
        guard let slashIndex = target.lastIndex(of: "/") else { return newName }
        return String(target[target.startIndex...slashIndex]) + newName
    }
}
