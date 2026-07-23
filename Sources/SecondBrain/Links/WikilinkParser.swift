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
//
// concealShape (Live Preview, см. MarkdownEditorView/ConcealableMarker): какую
// часть ссылки видно всегда (target либо alias), а что можно свернуть, пока
// курсор не на этой строке. Формула одна для всех форм ссылки — «скрыть от
// начала [[ до начала видимой части» и «скрыть от конца видимой части до ]]»:
// для [[target]] видимая часть — target (префикс = «[[», суффикс = «]]»);
// для [[target|alias]] видимая часть — alias (префикс поглощает «target|»);
// для [[target#heading]] без алиаса видимая часть — target (суффикс поглощает
// «#heading]]») — общая формула сама подхватывает пробелы внутри скобок.

import Foundation

/// Одна wikilink в тексте: полный диапазон [[...]] + разобранные части.
struct Wikilink: Equatable {
    /// Диапазон всей конструкции [[...]] в UTF-16.
    let range: NSRange
    /// Точный диапазон сегмента цели (без пробелов) — для переписывания при переименовании (задача 54).
    let targetRange: NSRange
    /// Имя целевой заметки (возможно с путём «папка/Имя»), без расширения.
    let target: String
    /// Заголовок секции после «#», если есть.
    let heading: String?
    /// Отображаемый алиас после «|», если есть.
    let alias: String?
    /// Форма сворачивания для Live Preview — см. заголовок файла.
    let concealShape: ConcealShape

    /// Диапазоны, которые можно скрыть, и диапазон, который виден всегда.
    struct ConcealShape: Equatable {
        let hidePrefix: NSRange
        let hideSuffix: NSRange
        let visible: NSRange
    }

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

    /// Все wikilinks текста (вне код-блоков), в порядке появления.
    static func parse(_ text: String) -> [Wikilink] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let excluded = CodeRegionDetector.excludedRanges(in: text)

        var links: [Wikilink] = []
        for match in linkRegex.matches(in: text, range: full) {
            let range = match.range
            if CodeRegionDetector.isExcluded(range, from: excluded) {
                continue
            }
            if let link = parseInner(ns, innerRange: match.range(at: 1), matchRange: range) {
                links.append(link)
            }
        }
        return links
    }

    /// Разбор внутренности «цель#заголовок|алиас» + диапазоны для сворачивания.
    /// Работает в абсолютных UTF-16-координатах исходного текста (не пере-
    /// считывает по длине строк) — безопасно для кириллицы/эмодзи в имени.
    private static func parseInner(_ ns: NSString, innerRange: NSRange, matchRange: NSRange) -> Wikilink? {
        // Первое «|» и (до него) первое «#» — абсолютные диапазоны в ns.
        let pipeRange = ns.range(of: "|", range: innerRange)
        let hasPipe = pipeRange.location != NSNotFound
        let beforePipeRange = hasPipe
            ? NSRange(location: innerRange.location, length: pipeRange.location - innerRange.location)
            : innerRange
        let aliasRawRange = hasPipe
            ? NSRange(location: NSMaxRange(pipeRange), length: NSMaxRange(innerRange) - NSMaxRange(pipeRange))
            : NSRange(location: NSNotFound, length: 0)

        let hashRange = ns.range(of: "#", range: beforePipeRange)
        let hasHash = hashRange.location != NSNotFound
        let targetRawRange = hasHash
            ? NSRange(location: beforePipeRange.location, length: hashRange.location - beforePipeRange.location)
            : beforePipeRange
        let headingRawRange = hasHash
            ? NSRange(location: NSMaxRange(hashRange), length: NSMaxRange(beforePipeRange) - NSMaxRange(hashRange))
            : NSRange(location: NSNotFound, length: 0)

        let targetRange = trimmedRange(ns, in: targetRawRange)
        guard targetRange.length > 0 else { return nil }
        let target = ns.substring(with: targetRange)

        let headingRange = hasHash ? trimmedRange(ns, in: headingRawRange) : nil
        let heading = headingRange.flatMap { $0.length > 0 ? ns.substring(with: $0) : nil }

        let aliasRange = hasPipe ? trimmedRange(ns, in: aliasRawRange) : nil
        let alias = aliasRange.flatMap { $0.length > 0 ? ns.substring(with: $0) : nil }

        // Видимая часть — alias, если он реально непуст, иначе target (заголовок
        // секции, если есть без алиаса, тоже прячется вместе со скобками).
        let visible = (alias != nil) ? aliasRange! : targetRange
        let shape = Wikilink.ConcealShape(
            hidePrefix: NSRange(location: matchRange.location, length: visible.location - matchRange.location),
            hideSuffix: NSRange(location: NSMaxRange(visible), length: NSMaxRange(matchRange) - NSMaxRange(visible)),
            visible: visible
        )

        return Wikilink(range: matchRange, targetRange: targetRange, target: target, heading: heading, alias: alias, concealShape: shape)
    }

    /// Диапазон без ведущих/хвостовых пробелов — абсолютные UTF-16-координаты.
    /// Проверка через Unicode.Scalar(UInt16): для суррогатных половинок
    /// инициализатор проваливается (nil) — они безопасно считаются «не пробел».
    private static func trimmedRange(_ ns: NSString, in range: NSRange) -> NSRange {
        guard range.length > 0 else { return range }
        let whitespace = CharacterSet.whitespaces
        var start = range.location
        let end = NSMaxRange(range)
        while start < end, let scalar = Unicode.Scalar(ns.character(at: start)), whitespace.contains(scalar) {
            start += 1
        }
        var stop = end
        while stop > start, let scalar = Unicode.Scalar(ns.character(at: stop - 1)), whitespace.contains(scalar) {
            stop -= 1
        }
        return NSRange(location: start, length: stop - start)
    }
}
