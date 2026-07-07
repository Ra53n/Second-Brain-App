// WikilinkParser.swift — извлечение Obsidian-ссылок [[...]] из текста заметки.
//
// Поддерживаемые формы (синтаксис Obsidian):
//   [[Имя заметки]]            — цель;
//   [[Имя|алиас]]              — отображается алиас;
//   [[Имя#Заголовок]]          — ссылка на секцию;
//   [[Имя#Заголовок|алиас]]    — всё сразу;
//   [[папка/Имя]]              — цель с путём (резолв в LinkIndex).
//
// Не поддерживаем (сознательно): embed ![[...]] (вне объёма задачи 04),
// [[#Заголовок]] без имени (ссылка внутри той же заметки — редкость),
// пустые [[  ]]. Ссылки внутри код-блоков ``` и инлайн-кода ` игнорируются.
//
// Диапазоны — UTF-16 (NSRange): их потребляют NSTextStorage и подсветка.

import Foundation

/// Одна wikilink в тексте: полный диапазон [[...]] + разобранные части.
struct Wikilink: Equatable {
    /// Диапазон всей конструкции [[...]] в UTF-16.
    let range: NSRange
    /// Имя целевой заметки (возможно с путём «папка/Имя»), без расширения.
    let target: String
    /// Заголовок секции после «#», если есть.
    let heading: String?
    /// Отображаемый алиас после «|», если есть.
    let alias: String?

    /// Текст, который видит пользователь: алиас или цель (+заголовок).
    var displayText: String {
        if let alias { return alias }
        if let heading { return "\(target) › \(heading)" }
        return target
    }
}

/// Парсер wikilinks. Чистые статические функции, без состояния.
enum WikilinkParser {

    // [[внутренность]]: без вложенных скобок и переносов строк.
    private static let linkRegex = try! NSRegularExpression(
        pattern: "\\[\\[([^\\[\\]\\n]+?)\\]\\]"
    )
    // Код-регионы, внутри которых ссылки не считаются.
    private static let codeBlockRegex = try! NSRegularExpression(
        pattern: "^```[\\s\\S]*?^```", options: [.anchorsMatchLines]
    )
    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: "`[^`\\n]+`"
    )

    /// Все wikilinks текста (вне код-блоков), в порядке появления.
    static func parse(_ text: String) -> [Wikilink] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        let excluded = codeBlockRegex.matches(in: text, range: full).map(\.range)
            + inlineCodeRegex.matches(in: text, range: full).map(\.range)

        var links: [Wikilink] = []
        for match in linkRegex.matches(in: text, range: full) {
            let range = match.range
            if excluded.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                continue
            }
            let inner = ns.substring(with: match.range(at: 1))
            if let link = parseInner(inner, range: range) {
                links.append(link)
            }
        }
        return links
    }

    /// Разбор внутренности «цель#заголовок|алиас». Пустая цель → nil.
    private static func parseInner(_ inner: String, range: NSRange) -> Wikilink? {
        // Сначала «|»: алиас — всё справа от ПЕРВОЙ черты.
        let pipeSplit = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let beforePipe = String(pipeSplit[0])
        let aliasRaw = pipeSplit.count > 1 ? String(pipeSplit[1]).trimmingCharacters(in: .whitespaces) : nil

        // Потом «#»: заголовок — всё справа от ПЕРВОЙ решётки.
        let hashSplit = beforePipe.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let target = String(hashSplit[0]).trimmingCharacters(in: .whitespaces)
        let headingRaw = hashSplit.count > 1 ? String(hashSplit[1]).trimmingCharacters(in: .whitespaces) : nil

        guard !target.isEmpty else { return nil }
        return Wikilink(
            range: range,
            target: target,
            heading: headingRaw.flatMap { $0.isEmpty ? nil : $0 },
            alias: aliasRaw.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
