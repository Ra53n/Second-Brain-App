// ParagraphStyling.swift — межстрочные/межабзацные отступы для редактора заметки.
//
// Раньше подсветка (MarkdownHighlighter) трогала только символьные атрибуты
// (шрифт/цвет отдельных диапазонов) — ни одного NSParagraphStyle, поэтому текст
// выглядел одной сплошной стеной без визуальной иерархии. Здесь — чистая логика
// «что за абзац перед нами» и «какой отступ ему нужен», без AppKit-зависимостей
// (тестируется без NSTextView); применение — в MarkdownEditorView.Coordinator.
//
// «Абзац» здесь — логический markdown-блок между пустыми строками; заголовок
// всегда сам себе абзац из одной строки (даже без пустой строки перед соседним
// текстом — смена типа обязана визуально разрывать поток), пункт списка — тоже
// всегда одна строка (у каждого свой уровень вложенности → свой отступ, поэтому
// список не собирается в один общий абзац). Числа отступов рассчитаны на
// базовый шрифт 15pt (MarkdownEditorView.baseFontSize) — при изменении базового
// размера стоит пересчитать.

import AppKit // NSParagraphStyle — часть AppKit, не чистого Foundation, на macOS

/// Вид абзаца — определяет отступы/интервалы.
enum ParagraphKind: Equatable {
    case heading(level: Int)
    case listItem(indentLevel: Int)
    case blockquote
    case body
}

/// Один логический абзац: диапазон в тексте + его вид.
struct ParagraphRange: Equatable {
    let range: NSRange
    let kind: ParagraphKind
}

enum ParagraphStyling {

    // Отступ списка — всё, что до маркера (`-`/`*`/`+`/`1.`), группа 1.
    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]")
    private static let listRegex = try! NSRegularExpression(pattern: "^(\\s*)(?:[-*+]|\\d+\\.)[ \\t]")
    private static let blockquoteRegex = try! NSRegularExpression(pattern: "^\\s*>")

    /// Абзацы текста в порядке появления, с их видом.
    static func paragraphRanges(in text: String) -> [ParagraphRange] {
        let ns = text as NSString
        var result: [ParagraphRange] = []
        var location = 0
        var groupStart: Int?
        var groupKind: ParagraphKind?
        var groupEnd = 0

        func flush() {
            guard let start = groupStart, let kind = groupKind else { return }
            result.append(ParagraphRange(range: NSRange(location: start, length: groupEnd - start), kind: kind))
            groupStart = nil
            groupKind = nil
        }

        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            guard lineRange.length > 0 else { break } // защита от зацикливания на вырожденном входе
            let lineText = ns.substring(with: lineRange)

            switch classify(lineText) {
            case .blank:
                flush()
            case .heading(let level):
                flush()
                result.append(ParagraphRange(range: lineRange, kind: .heading(level: level)))
            case .listItem(let indentLevel):
                flush()
                result.append(ParagraphRange(range: lineRange, kind: .listItem(indentLevel: indentLevel)))
            case .blockquote:
                if groupKind == .blockquote {
                    groupEnd = NSMaxRange(lineRange)
                } else {
                    flush()
                    groupStart = lineRange.location
                    groupKind = .blockquote
                    groupEnd = NSMaxRange(lineRange)
                }
            case .body:
                if groupKind == .body {
                    groupEnd = NSMaxRange(lineRange)
                } else {
                    flush()
                    groupStart = lineRange.location
                    groupKind = .body
                    groupEnd = NSMaxRange(lineRange)
                }
            }
            location = NSMaxRange(lineRange)
        }
        flush()
        return result
    }

    /// `NSParagraphStyle` для вида абзаца — конкретные точки, подобранные для 15pt
    /// (MarkdownEditorView.baseFontSize) с комфортным «обсидиановским» интерлиньяжем.
    static func style(for kind: ParagraphKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch kind {
        case .heading(let level):
            style.lineSpacing = 3
            switch level {
            case 1: style.paragraphSpacingBefore = 24; style.paragraphSpacing = 12
            case 2: style.paragraphSpacingBefore = 20; style.paragraphSpacing = 10
            case 3: style.paragraphSpacingBefore = 16; style.paragraphSpacing = 8
            default: style.paragraphSpacingBefore = 12; style.paragraphSpacing = 6
            }
        case .body:
            style.lineSpacing = 5
            style.paragraphSpacing = 10
        case .listItem(let indentLevel):
            style.lineSpacing = 4
            style.paragraphSpacing = 3
            style.headIndent = 24 + 20 * CGFloat(indentLevel)
            style.firstLineHeadIndent = 24 * CGFloat(indentLevel)
        case .blockquote:
            style.lineSpacing = 4
            style.paragraphSpacingBefore = 6
            style.paragraphSpacing = 10
            style.headIndent = 20
            style.firstLineHeadIndent = 20
        }
        return style
    }

    // MARK: - Внутреннее

    private enum LineKind: Equatable {
        case blank
        case heading(level: Int)
        case listItem(indentLevel: Int)
        case blockquote
        case body
    }

    private static func classify(_ line: String) -> LineKind {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .blank }

        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let match = headingRegex.firstMatch(in: line, range: full) {
            return .heading(level: match.range(at: 1).length)
        }
        // Отступ списка меряем в «условных единицах» по 2 символа (пробела) на
        // уровень — приближение: табы считаются как один символ отступа.
        if let match = listRegex.firstMatch(in: line, range: full) {
            let indentChars = match.range(at: 1).length
            return .listItem(indentLevel: indentChars / 2)
        }
        if blockquoteRegex.firstMatch(in: line, range: full) != nil {
            return .blockquote
        }
        return .body
    }
}
