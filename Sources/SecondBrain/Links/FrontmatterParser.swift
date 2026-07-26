// FrontmatterParser.swift — плоский YAML-frontmatter между «---» в начале файла.
//
// Сознательно НЕ полноценный YAML (задача 04: «не тащи YAML-библиотеку»).
// Поддерживается плоская структура:
//   key: строка | число | дата YYYY-MM-DD | [a, b] | блок-список из «- item»
// Ограничения (документировано здесь):
//   - без вложенных объектов, многострочных значений (|, >), якорей;
//   - разделители строк — \n (не \r\n);
//   - нераспознанные строки НЕ теряются: хранятся как raw и сериализуются
//     обратно байт-в-байт — round-trip не портит чужой frontmatter;
//   - битый frontmatter (нет закрывающего «---») → весь файл считается телом.

import Foundation

/// Типизированное значение поля frontmatter.
enum FrontmatterValue: Equatable {
    case string(String)
    case number(Double)
    case date(Date)     // только YYYY-MM-DD
    case list([String])
}

/// Разобранный документ: поля + тело. Сериализация собирает файл обратно,
/// не тронутые поля воспроизводятся из исходных строк дословно.
struct FrontmatterDocument: Equatable {

    /// Запись frontmatter: типизированное поле или непонятая строка (raw).
    struct Entry: Equatable {
        /// Ключ поля; nil — raw-строка (комментарий, вложенный YAML и т.п.).
        let key: String?
        let value: FrontmatterValue?
        /// Исходные строки записи — для сериализации без потерь.
        var rawLines: [String]
    }

    var entries: [Entry]
    /// Текст после frontmatter (или весь файл, если frontmatter нет/битый).
    var body: String
    /// Была ли в исходном файле пустая frontmatter-заготовка (---\n---\n)
    /// без единого поля внутри. Различает "нет frontmatter вовсе" от
    /// "есть пустой блок frontmatter", без чего round-trip теряет маркеры.
    /// Умышленно не трогается subscript-мутацией: отражает только состояние на
    /// момент parse, не путь программного изменения (см. LinksTests.
    /// testEmptyFrontmatterSerializesToBodyOnly — удаление последнего поля
    /// схлопывает блок в body, а не сохраняет пустые маркеры).
    var hasEmptyFrontmatterBlock: Bool = false

    /// Значение поля по ключу (первое совпадение).
    subscript(key: String) -> FrontmatterValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            guard let newValue else {
                entries.removeAll { $0.key == key }
                return
            }
            let entry = Entry(
                key: key,
                value: newValue,
                rawLines: Self.canonicalLines(key: key, value: newValue)
            )
            if let index = entries.firstIndex(where: { $0.key == key }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
    }

    /// Собирает файл обратно: «---» + записи (raw-строки дословно) + «---» + тело.
    /// Без единой записи блок frontmatter не пишется вовсе, кроме случая
    /// пустой заготовки (hasEmptyFrontmatterBlock=true) — тогда выдаёт маркеры
    /// «---\n---\n» для round-trip.
    func serialized() -> String {
        if entries.isEmpty {
            return hasEmptyFrontmatterBlock ? "---\n---\n" + body : body
        }
        let lines = entries.flatMap(\.rawLines)
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    /// Каноничный вид поля при программном изменении (исходное форматирование
    /// в этом случае уже не сохранить).
    private static func canonicalLines(key: String, value: FrontmatterValue) -> [String] {
        switch value {
        case .string(let string):
            return ["\(key): \(string)"]
        case .number(let number):
            let isInteger = number == number.rounded() && abs(number) < 1e15
            return ["\(key): \(isInteger ? String(Int(number)) : String(number))"]
        case .date(let date):
            return ["\(key): \(FrontmatterParser.dateFormatter.string(from: date))"]
        case .list(let items):
            return ["\(key):"] + items.map { "  - \($0)" }
        }
    }
}

/// Парсер frontmatter. Никогда не бросает: любой мусор → raw-строки или тело.
enum FrontmatterParser {

    /// YYYY-MM-DD в UTC — дата без времени, как принято в Obsidian.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parse(_ text: String) -> FrontmatterDocument {
        // Frontmatter начинается СТРОГО с «---» первой строкой.
        guard text.hasPrefix("---\n") || text == "---" else {
            return FrontmatterDocument(entries: [], body: text)
        }
        let lines = text.components(separatedBy: "\n")
        // Закрывающий «---» — отдельной строкой после первой.
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return FrontmatterDocument(entries: [], body: text) // битый — весь файл тело
        }

        let fieldLines = Array(lines[1..<closingIndex])
        let body = lines[(closingIndex + 1)...].joined(separator: "\n")
        let entries = parseEntries(fieldLines)
        var doc = FrontmatterDocument(entries: entries, body: body)
        doc.hasEmptyFrontmatterBlock = fieldLines.isEmpty
        return doc
    }

    // MARK: - Внутреннее

    private static let keyLineRegex = try! NSRegularExpression(
        pattern: "^([^\\s:][^:]*):\\s*(.*)$"
    )
    private static let listItemRegex = try! NSRegularExpression(
        pattern: "^\\s*-\\s+(.*)$"
    )
    private static let numberRegex = try! NSRegularExpression(
        pattern: "^-?\\d+(\\.\\d+)?$"
    )
    private static let dateRegex = try! NSRegularExpression(
        pattern: "^\\d{4}-\\d{2}-\\d{2}$"
    )

    private static func parseEntries(_ lines: [String]) -> [FrontmatterDocument.Entry] {
        var entries: [FrontmatterDocument.Entry] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            guard let match = keyLineRegex.firstMatch(in: line, range: full) else {
                // Непонятая строка (комментарий, вложенность) — сохранить дословно.
                entries.append(.init(key: nil, value: nil, rawLines: [line]))
                index += 1
                continue
            }

            let key = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let rawValue = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            var rawLines = [line]

            if rawValue.isEmpty {
                // «key:» без значения — возможно, блок-список «- item» ниже.
                var items: [String] = []
                var next = index + 1
                while next < lines.count,
                      let itemMatch = listItemRegex.firstMatch(
                        in: lines[next],
                        range: NSRange(location: 0, length: (lines[next] as NSString).length)
                      ) {
                    items.append(unquote((lines[next] as NSString).substring(with: itemMatch.range(at: 1))))
                    rawLines.append(lines[next])
                    next += 1
                }
                entries.append(.init(
                    key: key,
                    value: items.isEmpty ? .string("") : .list(items),
                    rawLines: rawLines
                ))
                index = next
            } else {
                entries.append(.init(key: key, value: parseScalar(rawValue), rawLines: rawLines))
                index += 1
            }
        }
        return entries
    }

    /// Скаляр: [список], число, дата, иначе строка (кавычки снимаются).
    private static func parseScalar(_ raw: String) -> FrontmatterValue {
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast())
            let items = inner.split(separator: ",")
                .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            return .list(items)
        }
        let full = NSRange(location: 0, length: (raw as NSString).length)
        if numberRegex.firstMatch(in: raw, range: full) != nil, let number = Double(raw) {
            return .number(number)
        }
        if dateRegex.firstMatch(in: raw, range: full) != nil, let date = dateFormatter.date(from: raw) {
            return .date(date)
        }
        return .string(unquote(raw))
    }

    /// Снимает одинарные/двойные кавычки по краям, если они парные.
    private static func unquote(_ string: String) -> String {
        for quote in ["\"", "'"] where string.count >= 2
            && string.hasPrefix(quote) && string.hasSuffix(quote) {
            return String(string.dropFirst().dropLast())
        }
        return string
    }
}
