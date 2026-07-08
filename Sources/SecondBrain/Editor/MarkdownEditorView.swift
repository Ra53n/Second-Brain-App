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
// Чеклисты `- [ ]`/`- [x]` (ChecklistParser.swift): маркер и завершённый текст
// подсвечиваются, обычный клик (без Cmd) по «[ ]»/«[x]» переключает состояние
// прямо в тексте — см. заголовок ChecklistParser.swift о том, почему не WYSIWYG.
//
// Типографика (NSParagraphStyle — см. ParagraphStyling.swift): межстрочные и
// межабзацные отступы, отступы списков — раньше их не было вовсе, текст выглядел
// сплошной стеной.
//
// Служебный Obsidian-синтаксис — блок-ссылки `^id` (BlockReferenceParser.swift)
// и скрытые `%% %%`-комментарии (CommentBlockParser.swift) — ведёт себя как в
// Obsidian Live Preview: свёрнут (мелкий приглушённый текст), пока курсор
// редактирования не встанет на эту строку/внутрь блока, тогда раскрывается до
// нормального размера. Настоящее «схлопывание до нулевой ширины» без изменения
// textView.string потребовало бы кастомного TextKit-typesetter'а — вместо этого
// используется тот же механизм атрибутов (шрифт/цвет), что и везде в этом файле,
// реагирующий на textViewDidChangeSelection; см. Coordinator.restyleConcealedRanges.
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
        case highlight           // ==выделение== (Obsidian)
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
    private static let highlightRegex = try! NSRegularExpression(
        pattern: "==[^=\n]+=="
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
        for match in highlightRegex.matches(in: text, range: full) {
            result.append(Match(kind: .highlight, range: match.range))
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

    /// Cmd+клик по wikilink — переход; обычный клик по «[ ]»/«[x]» — переключение
    /// чеклиста (без модификатора, как клик по чекбоксу в Obsidian); иначе —
    /// обычное поведение (позиционирование курсора/выделение).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)

        if event.modifierFlags.contains(.command) {
            if let link = wikilinkAt?(index) {
                onWikilinkClick?(link.target)
                return
            }
        } else if let item = ChecklistParser.parse(string).first(where: {
            NSLocationInRange(index, $0.markerRange)
        }) {
            toggleChecklistMarker(item)
            return
        }
        super.mouseDown(with: event)
    }

    /// Переключает «[ ]»↔«[x]» через shouldChangeText/didChangeText — так же,
    /// как правки с клавиатуры: попадает в undo-стек и триггерит textDidChange
    /// (перекраска + автосохранение), а не только правится textStorage напрямую.
    func toggleChecklistMarker(_ item: ChecklistItem) {
        let replacement = ChecklistParser.toggledMarker(currentlyChecked: item.isChecked)
        guard shouldChangeText(in: item.markerRange, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: item.markerRange, with: replacement)
        didChangeText()
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
        /// Блок-ссылки и скрытые комментарии текущего текста — свежие после
        /// каждого полного highlight(_:); restyleConcealedRanges переиспользует
        /// их без повторного парсинга при каждом движении курсора.
        private var currentBlockRefs: [BlockReference] = []
        private var currentCommentBlocks: [CommentBlock] = []

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

        /// Курсор/выделение сдвинулись — разворачиваем свёрнутые блок-ссылки/
        /// комментарии под курсором, сворачиваем остальные. НЕ гоняет полный
        /// regex-скан документа (тот остаётся только на textDidChange) — только
        /// перекрашивает уже распарсенные диапазоны из currentBlockRefs/
        /// currentCommentBlocks, поэтому на каждое нажатие стрелки не нагружает.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            restyleConcealedRanges(textView)
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

        /// Красит текст целиком: сброс к базовому стилю → абзацные отступы →
        /// разметка → wikilinks → чеклисты → скрываемый Obsidian-синтаксис.
        /// Единственное место, где документ перепарсивается регэкспами —
        /// зовётся на textDidChange и при подмене файла, НЕ на каждое движение
        /// курсора (для этого — restyleConcealedRanges, ниже).
        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            storage.beginEditing()
            applyBaseAttributes(storage)
            applyParagraphStyles(storage, text: textView.string)
            applyMarkdownHighlighterMatches(storage, text: textView.string)
            applyWikilinks(storage, text: textView.string)
            applyChecklists(storage, text: textView.string)
            applyConcealables(storage, textView: textView)
            storage.endEditing()
        }

        /// Реакция на движение курсора: перекрашивает УЖЕ распарсенные (см.
        /// applyConcealables) блок-ссылки/комментарии по новой позиции курсора.
        /// Без regex-скана документа — дёшево даже на каждое нажатие стрелки.
        func restyleConcealedRanges(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            storage.beginEditing()
            styleConcealables(storage, caret: textView.selectedRange())
            storage.endEditing()
        }

        private func applyBaseAttributes(_ storage: NSTextStorage) {
            let full = NSRange(location: 0, length: storage.length)
            storage.setAttributes([
                .font: NSFont.systemFont(ofSize: MarkdownEditorView.baseFontSize),
                .foregroundColor: NSColor.textColor
            ], range: full)
        }

        /// Отступы абзацев (ParagraphStyling) — до символьных атрибутов ниже,
        /// они трогают только узкие под-диапазоны и .paragraphStyle не касаются.
        private func applyParagraphStyles(_ storage: NSTextStorage, text: String) {
            for paragraph in ParagraphStyling.paragraphRanges(in: text) {
                storage.addAttribute(.paragraphStyle, value: ParagraphStyling.style(for: paragraph.kind), range: paragraph.range)
            }
        }

        private func applyMarkdownHighlighterMatches(_ storage: NSTextStorage, text: String) {
            let mono = NSFont.monospacedSystemFont(ofSize: MarkdownEditorView.baseFontSize - 1, weight: .regular)
            for match in MarkdownHighlighter.matches(in: text) {
                switch match.kind {
                case .heading(let level):
                    let size = MarkdownHighlighter.headingFontSize(level: level, base: MarkdownEditorView.baseFontSize)
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: match.range)
                case .bold:
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: MarkdownEditorView.baseFontSize), range: match.range)
                case .highlight:
                    // «Маркер»-заливка (Obsidian ==выделение==) — жёлтый адаптируется
                    // к light/dark сам, альфа держит текст читаемым поверх.
                    storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: match.range)
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
        }

        /// Wikilinks — акцентный цвет + подчёркивание; Cmd+клик обрабатывает
        /// MarkdownTextView (атрибут .link не ставим: обычный клик по нему
        /// уводил бы в NSWorkspace вместо позиционирования курсора).
        private func applyWikilinks(_ storage: NSTextStorage, text: String) {
            currentLinks = WikilinkParser.parse(text)
            for link in currentLinks {
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: link.range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: link.range)
            }
        }

        /// Чеклисты: маркер жирный (акцент — незавершён, приглушённый — готов),
        /// текст выполненного пункта зачёркнут и приглушён — как в Obsidian.
        private func applyChecklists(_ storage: NSTextStorage, text: String) {
            for item in ChecklistParser.parse(text) {
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: MarkdownEditorView.baseFontSize), range: item.markerRange)
                storage.addAttribute(
                    .foregroundColor,
                    value: item.isChecked ? NSColor.secondaryLabelColor : NSColor.controlAccentColor,
                    range: item.markerRange
                )
                if item.isChecked {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: item.contentRange)
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: item.contentRange)
                }
            }
        }

        /// Парсит блок-ссылки/комментарии заново (полный проход — только отсюда,
        /// на textDidChange), кэширует в currentBlockRefs/currentCommentBlocks
        /// и красит по текущей позиции курсора.
        private func applyConcealables(_ storage: NSTextStorage, textView: NSTextView) {
            currentBlockRefs = BlockReferenceParser.parse(textView.string)
            currentCommentBlocks = CommentBlockParser.parse(textView.string)
            styleConcealables(storage, caret: textView.selectedRange())
        }

        /// Красит блок-ссылки/комментарии по УЖЕ закэшированным диапазонам:
        /// свёрнуты (мелкий приглушённый текст), если курсор не на них,
        /// развёрнуты (нормальный размер, для комментариев — моноширинный
        /// код-блок), если курсор внутри — как Obsidian Live Preview.
        private func styleConcealables(_ storage: NSTextStorage, caret: NSRange) {
            let mono = NSFont.monospacedSystemFont(ofSize: MarkdownEditorView.baseFontSize - 1, weight: .regular)

            for ref in currentBlockRefs {
                if Self.selection(caret, overlaps: ref.lineRange) {
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: MarkdownEditorView.baseFontSize), range: ref.range)
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: ref.range)
                } else {
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 5), range: ref.range)
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: ref.range)
                }
            }

            for block in currentCommentBlocks {
                if Self.selection(caret, overlaps: block.range) {
                    storage.addAttribute(.font, value: mono, range: block.range)
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: block.range)
                    storage.addAttribute(
                        .backgroundColor,
                        value: NSColor.textBackgroundColor.blended(withFraction: 0.5, of: .quaternaryLabelColor) ?? .quaternaryLabelColor,
                        range: block.range
                    )
                } else {
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 4), range: block.range)
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: block.range)
                    storage.removeAttribute(.backgroundColor, range: block.range)
                }
            }
        }

        /// true, если курсор/выделение пересекается с range. Коллапсированный
        /// курсор считается «пересекающим», если стоит внутри ИЛИ ровно на правой
        /// границе (частый случай — курсор сразу после «^id» в конце строки).
        /// Активное выделение — обычное пересечение диапазонов: если выделение
        /// частично захватывает скрытый текст, copy/cut не должен обескураживать
        /// пользователя невидимым содержимым.
        private static func selection(_ caret: NSRange, overlaps range: NSRange) -> Bool {
            if caret.length == 0 {
                return NSLocationInRange(caret.location, range) || caret.location == NSMaxRange(range)
            }
            return NSIntersectionRange(caret, range).length > 0
        }
    }
}
