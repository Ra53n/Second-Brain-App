// MarkdownEditorView.swift — редактор заметки: NSTextView + подсветка + wikilinks.
//
// Здесь живут:
//  - MarkdownHighlighter  — поиск диапазонов разметки (заголовки, жирный, код…);
//                           чистая логика, покрыта тестами;
//  - MarkdownTextView     — подкласс NSTextView: автокомплит [[ и Cmd+клик;
//  - MarkdownEditorView   — NSViewRepresentable-обёртка.
//
// Wikilinks (задача 04): ввод «[[» открывает автокомплит по заметкам vault
// (штатный completion-попап NSTextView с нашим rangeForUserCompletion — иначе
// имена с пробелами резались бы по границе слова); Cmd+клик по [[ссылке]]
// открывает/создаёт заметку (как в Obsidian; без Cmd клик просто ставит курсор).
//
// Почему NSTextView, а не SwiftUI TextEditor: на больших файлах TextEditor
// тормозит (подсказка задачи 03). Подсветка «лёгкая» — атрибуты поверх текста,
// без изменения содержимого; полноценный syntax highlight не цель.

import SwiftUI
import AppKit

/// Поиск диапазонов markdown-разметки в тексте. Регэкспы по всему документу
/// на каждый ввод — для заметок это дёшево; оптимизация по viewport — задача 19.
enum MarkdownHighlighter {

    /// Вид найденного фрагмента разметки.
    enum Kind: Equatable {
        case heading(level: Int) // # .. ######
        case bold                // **жирный**
        case inlineCode          // `код`
        case codeBlock           // ```…```
        case blockquote          // > цитата
    }

    struct Match: Equatable {
        let kind: Kind
        let range: NSRange
    }

    // Скомпилированы один раз: подсветка зовётся на каждый ввод символа.
    private static let headingRegex = try! NSRegularExpression(
        pattern: "^(#{1,6})[ \t].*$", options: [.anchorsMatchLines]
    )
    private static let boldRegex = try! NSRegularExpression(
        pattern: "\\*\\*[^*\n]+\\*\\*"
    )
    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: "`[^`\n]+`"
    )
    private static let codeBlockRegex = try! NSRegularExpression(
        pattern: "^```[\\s\\S]*?^```", options: [.anchorsMatchLines]
    )
    private static let blockquoteRegex = try! NSRegularExpression(
        pattern: "^>[ \t].*$", options: [.anchorsMatchLines]
    )

    /// Все совпадения разметки в тексте. Диапазоны — в UTF-16 (NSString),
    /// как того требуют NSTextStorage/NSRegularExpression.
    static func matches(in text: String) -> [Match] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result: [Match] = []

        for match in headingRegex.matches(in: text, range: full) {
            let level = match.range(at: 1).length
            result.append(Match(kind: .heading(level: level), range: match.range))
        }
        for match in boldRegex.matches(in: text, range: full) {
            result.append(Match(kind: .bold, range: match.range))
        }
        for match in inlineCodeRegex.matches(in: text, range: full) {
            result.append(Match(kind: .inlineCode, range: match.range))
        }
        for match in codeBlockRegex.matches(in: text, range: full) {
            result.append(Match(kind: .codeBlock, range: match.range))
        }
        for match in blockquoteRegex.matches(in: text, range: full) {
            result.append(Match(kind: .blockquote, range: match.range))
        }
        return result
    }

    /// Размер шрифта заголовка по уровню (# крупнее, чем ######).
    static func headingFontSize(level: Int, base: CGFloat) -> CGFloat {
        switch level {
        case 1: return base + 8
        case 2: return base + 5
        case 3: return base + 3
        default: return base + 1
        }
    }
}

/// NSTextView с поддержкой wikilinks: свой диапазон автокомплита (от «[[» до
/// курсора, а не «последнее слово») и Cmd+клик по ссылке.
final class MarkdownTextView: NSTextView {

    /// Wikilink по UTF-16-индексу символа (для Cmd+клика); ставит Coordinator.
    var wikilinkAt: ((Int) -> Wikilink?)?
    /// Обработчик Cmd+клика по ссылке (цель ссылки).
    var onWikilinkClick: ((String) -> Void)?

    /// Незакрытая «[[…» слева от курсора: диапазон запроса (после «[[»).
    /// nil — курсор не в контексте wikilink.
    var wikilinkQueryRange: NSRange {
        let cursor = selectedRange().location
        guard cursor != NSNotFound else { return NSRange(location: NSNotFound, length: 0) }
        let ns = string as NSString
        let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
        let beforeCursor = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        // Последнее «[[» без «]]» и «[»/«]» после него — открытый контекст ссылки.
        guard let open = beforeCursor.range(of: "[[", options: .backwards) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let afterOpen = beforeCursor[open.upperBound...]
        guard !afterOpen.contains("]"), !afterOpen.contains("[") else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let queryStart = lineStart + (beforeCursor as NSString).range(of: "[[", options: .backwards).location + 2
        return NSRange(location: queryStart, length: cursor - queryStart)
    }

    /// Штатный автокомплит заменяет «последнее слово» — для имён с пробелами
    /// («Финансы и активы») отдаём весь запрос от «[[» до курсора.
    override var rangeForUserCompletion: NSRange {
        let range = wikilinkQueryRange
        return range.location == NSNotFound ? super.rangeForUserCompletion : range
    }

    /// Cmd+клик по wikilink — переход; обычный клик — обычное поведение.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if let link = wikilinkAt?(index) {
                onWikilinkClick?(link.target)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Cmd+Return — переход по ссылке под курсором (как в Obsidian).
    /// Курсор сразу за «]]» тоже считается «на ссылке» — частый случай после
    /// автокомплита.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        if isReturn, event.modifierFlags.contains(.command) {
            let cursor = selectedRange().location
            if let link = wikilinkAt?(cursor) ?? (cursor > 0 ? wikilinkAt?(cursor - 1) : nil) {
                onWikilinkClick?(link.target)
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// NSTextView-редактор с binding текста и подсветкой. Фокус ставится сам —
/// новая заметка из дерева сразу готова к вводу (критерий задачи 03).
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    /// Цели для автокомплита [[ (имена заметок vault). Зовётся при показе попапа.
    var completionTargets: () -> [String] = { [] }
    /// Переход по wikilink (Cmd+клик): открыть или создать заметку.
    var onWikilinkClick: (String) -> Void = { _ in }

    fileprivate static let baseFontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, completionTargets: completionTargets, onWikilinkClick: onWikilinkClick)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Ручная сборка вместо scrollableTextView(): нужен наш подкласс.
        let textView = MarkdownTextView()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: Self.baseFontSize)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        // Смарт-подстановки ломают markdown («умные» кавычки, тире, ссылки) — глушим.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        textView.wikilinkAt = { [weak coordinator = context.coordinator] index in
            coordinator?.wikilink(at: index)
        }
        textView.onWikilinkClick = context.coordinator.onWikilinkClick

        textView.string = text
        context.coordinator.highlight(textView)

        // Курсор сразу в тексте: окно может ещё собираться — через async.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        // Замыкания могли устареть при смене файла — освежаем.
        context.coordinator.onWikilinkClick = onWikilinkClick
        context.coordinator.completionTargets = completionTargets
        // Обновляем только при внешней замене текста (открыли другой файл,
        // перечитали с диска) — во время набора string уже совпадает с binding.
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    /// Делегат NSTextView: тянет правки в binding, перекрашивает разметку,
    /// открывает автокомплит в контексте «[[» и отдаёт кандидатов.
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var completionTargets: () -> [String]
        var onWikilinkClick: (String) -> Void
        /// Ссылки текущего текста — для Cmd+клика и подсветки.
        private var currentLinks: [Wikilink] = []

        init(
            text: Binding<String>,
            completionTargets: @escaping () -> [String],
            onWikilinkClick: @escaping (String) -> Void
        ) {
            self.text = text
            self.completionTargets = completionTargets
            self.onWikilinkClick = onWikilinkClick
        }

        func wikilink(at index: Int) -> Wikilink? {
            currentLinks.first { NSLocationInRange(index, $0.range) }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            text.wrappedValue = textView.string
            highlight(textView)

            // Курсор в незакрытом «[[…» — показать/обновить попап автокомплита.
            if textView.wikilinkQueryRange.location != NSNotFound {
                textView.complete(nil)
            }
        }

        /// Кандидаты для попапа: fuzzy-фильтр имён заметок + закрывающие «]]».
        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            guard let markdownView = textView as? MarkdownTextView,
                  markdownView.wikilinkQueryRange.location != NSNotFound else {
                return words // вне контекста [[ — системное поведение
            }
            let query = (textView.string as NSString).substring(with: charRange)
            let matches = FuzzyMatch.filter(query, candidates: completionTargets())
            index?.pointee = -1 // ничего не предвыбираем: Enter без стрелок не съест ввод

            // После курсора уже есть «]]» (например, автокомплит перезапущен) —
            // не дублируем закрывающие скобки.
            let ns = textView.string as NSString
            let cursorEnd = charRange.location + charRange.length
            let alreadyClosed = cursorEnd + 2 <= ns.length
                && ns.substring(with: NSRange(location: cursorEnd, length: 2)) == "]]"
            return matches.map { alreadyClosed ? $0 : "\($0)]]" }
        }

        /// Красит текст по диапазонам MarkdownHighlighter + wikilinks: сброс к
        /// базовому стилю + атрибуты поверх. Содержимое не меняется.
        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let base = NSFont.systemFont(ofSize: MarkdownEditorView.baseFontSize)
            let mono = NSFont.monospacedSystemFont(ofSize: MarkdownEditorView.baseFontSize - 1, weight: .regular)
            let full = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.setAttributes([
                .font: base,
                .foregroundColor: NSColor.textColor
            ], range: full)

            for match in MarkdownHighlighter.matches(in: textView.string) {
                switch match.kind {
                case .heading(let level):
                    let size = MarkdownHighlighter.headingFontSize(level: level, base: MarkdownEditorView.baseFontSize)
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: match.range)
                case .bold:
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: MarkdownEditorView.baseFontSize), range: match.range)
                case .inlineCode, .codeBlock:
                    storage.addAttribute(.font, value: mono, range: match.range)
                    storage.addAttribute(
                        .backgroundColor,
                        value: NSColor.textBackgroundColor.blended(withFraction: 0.5, of: .quaternaryLabelColor) ?? .quaternaryLabelColor,
                        range: match.range
                    )
                case .blockquote:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
                }
            }

            // Wikilinks — акцентный цвет + подчёркивание; Cmd+клик обрабатывает
            // MarkdownTextView (атрибут .link не ставим: обычный клик по нему
            // уводил бы в NSWorkspace вместо позиционирования курсора).
            currentLinks = WikilinkParser.parse(textView.string)
            for link in currentLinks {
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: link.range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: link.range)
            }
            storage.endEditing()
        }
    }
}
