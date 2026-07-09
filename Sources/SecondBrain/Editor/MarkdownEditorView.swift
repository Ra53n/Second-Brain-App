// MarkdownEditorView.swift — редактор заметки: NSTextView + подсветка + wikilinks.
//
// Здесь живут:
//  - MarkdownHighlighter  — поиск диапазонов разметки (заголовки, жирный, код…);
//                           чистая логика, покрыта тестами;
//  - MarkdownTextView     — подкласс NSTextView: автокомплит [[, Cmd+клик,
//                           обсидиановские удобства (авто-списки, ⌘B/⌘I, парность);
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
// Live Preview (единственный режим редактора — Сплит/Превью убраны): маркеры
// разметки (#, **, ==, `, [[/]], >, -/1., ``` fences, служебные `^id`/`%% %%`
// Obsidian) НЕВИДИМЫ (глифы нуллифицируются — нулевая ширина, не рисуются, файл
// не меняется; см. ConcealingLayoutDelegate), пока курсор редактирования не
// встанет на эту строку/внутрь блока, тогда проявляются (для %%/``` —
// моноширинными с фоном код-блока). Содержимое (жирный текст, код и т.п.)
// стилизуется ВСЕГДА, независимо от сокрытия. Единая модель маркеров —
// ConcealableMarker.swift; сокрытие/проявление по позиции курсора —
// Coordinator.restyleConcealedRanges (реагирует на textViewDidChangeSelection,
// диффом трогает только изменившиеся маркеры).
//
// ПОДСВЕТКА ИНКРЕМЕНТАЛЬНАЯ (иначе «весь текст дёргается»): на каждое нажатие
// перекрашивается/перепарсивается ТОЛЬКО блок вокруг правки, не весь документ.
// Как это устроено:
//  - textStorage-делегат (didProcessEditing) лишь ЗАПИСЫВАет диапазон правки в
//    pendingEdit (атрибуты внутри processEditing трогать нельзя — сдвигает каретку);
//  - textDidChange применяет: highlightIncrementally для обычной правки (блок из
//    BlockRange.enclosingBlock) или highlight (полный проход) — только на открытии,
//    внешней перезагрузке и структурной правке (needsFullRehighlight: код-фенс ```
//    или %%-комментарий могут «протечь» за границу блока);
//  - кэш маркеров currentConcealables пересобирается инкрементально
//    (rebuiltConcealables): маркеры блока перепарсиваются, остальные сдвигаются на
//    изменение длины — быстрее полного парса и без полного релэйаута.
// Открытие без «прыжка»: стилизованная строка и concealedRanges ставятся ДО
// первого лэйаута (buildStyledAttributedString + primeConcealment), поэтому маркеры
// свёрнуты с первого кадра — без видимого схлопывания.
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
        /// Диапазоны маркеров разметки (без содержимого) — для Live Preview
        /// сворачивания (ConcealableMarker.forHighlighterMatch): heading — сами
        /// «#», bold/highlight/inlineCode — открывающий+закрывающий разделитель,
        /// blockquote — префикс «> ». Пусто для codeBlock — границы код-блока
        /// считаются отдельно (ищутся построчно от match.range, не regex-группой).
        let markerRanges: [NSRange]
    }

    // Скомпилированы один раз: подсветка зовётся на каждый ввод символа.
    // Группы вокруг разделителей (bold/highlight/inlineCode/blockquote) — не
    // только для markerRanges, но и чтобы content-диапазон остался доступен
    // при необходимости через match.range(at: 2).
    private static let headingRegex = try! NSRegularExpression(
        pattern: "^(#{1,6})[ \t].*$", options: [.anchorsMatchLines]
    )
    private static let boldRegex = try! NSRegularExpression(
        pattern: "(\\*\\*)([^*\n]+)(\\*\\*)"
    )
    private static let highlightRegex = try! NSRegularExpression(
        pattern: "(==)([^=\n]+)(==)"
    )
    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: "(`)([^`\n]+)(`)"
    )
    private static let codeBlockRegex = try! NSRegularExpression(
        pattern: "^```[\\s\\S]*?^```", options: [.anchorsMatchLines]
    )
    private static let blockquoteRegex = try! NSRegularExpression(
        pattern: "^(>[ \t])(.*)$", options: [.anchorsMatchLines]
    )

    /// Все совпадения разметки в тексте. Диапазоны — в UTF-16 (NSString),
    /// как того требуют NSTextStorage/NSRegularExpression.
    static func matches(in text: String) -> [Match] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result: [Match] = []

        for match in headingRegex.matches(in: text, range: full) {
            let level = match.range(at: 1).length
            result.append(Match(kind: .heading(level: level), range: match.range, markerRanges: [match.range(at: 1)]))
        }
        for match in boldRegex.matches(in: text, range: full) {
            result.append(Match(kind: .bold, range: match.range, markerRanges: [match.range(at: 1), match.range(at: 3)]))
        }
        for match in highlightRegex.matches(in: text, range: full) {
            result.append(Match(kind: .highlight, range: match.range, markerRanges: [match.range(at: 1), match.range(at: 3)]))
        }
        for match in inlineCodeRegex.matches(in: text, range: full) {
            result.append(Match(kind: .inlineCode, range: match.range, markerRanges: [match.range(at: 1), match.range(at: 3)]))
        }
        for match in codeBlockRegex.matches(in: text, range: full) {
            result.append(Match(kind: .codeBlock, range: match.range, markerRanges: []))
        }
        for match in blockquoteRegex.matches(in: text, range: full) {
            result.append(Match(kind: .blockquote, range: match.range, markerRanges: [match.range(at: 1)]))
        }
        return result
    }

    /// Размер шрифта заголовка по уровню (# крупнее, чем ######). Множители — как
    /// в Obsidian: заметная иерархия сверху, H5/H6 у размера тела (отличаются весом).
    static func headingFontSize(level: Int, base: CGFloat) -> CGFloat {
        switch level {
        case 1: return base * 1.8
        case 2: return base * 1.5
        case 3: return base * 1.3
        case 4: return base * 1.15
        case 5: return base * 1.05
        default: return base
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

    /// Cmd+Return — переход по ссылке под курсором (как в Obsidian; курсор сразу за
    /// «]]» тоже «на ссылке»). ⌘B/⌘I — жирный/курсив вокруг выделения (toggle).
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        if isReturn, event.modifierFlags.contains(.command) {
            let cursor = selectedRange().location
            if let link = wikilinkAt?(cursor) ?? (cursor > 0 ? wikilinkAt?(cursor - 1) : nil) {
                onWikilinkClick?(link.target)
                return
            }
        }
        // ⌘B/⌘I — только command (без option/control), чтобы не перехватывать ⌘⌥ и пр.
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods == .command {
            switch event.charactersIgnoringModifiers {
            case "b": applyWrapToggle(marker: "**"); return
            case "i": applyWrapToggle(marker: "*"); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// Enter внутри пункта списка — авто-продолжение (новый маркер / номер+1 /
    /// «[ ] »); на пустом пункте — выход из списка. Shift+Enter — обычный перенос.
    override func insertNewline(_ sender: Any?) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if !shift, !hasMarkedText(),
           let result = MarkdownEditingCommands.newlineInsertion(in: string as NSString, selection: selectedRange()) {
            applyEdit(result.replaceRange, with: result.replacement, cursor: NSRange(location: result.cursor, length: 0))
            return
        }
        super.insertNewline(sender)
    }

    /// Авто-парность: ввод `*`/`` ` ``/`_` при непустом выделении оборачивает его;
    /// ввод второго `[` (образуя «[[») авто-добавляет «]]», курсор между ними.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let typed = insertString as? String, !hasMarkedText() else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let selection = selectedRange()

        if selection.length > 0, let marker = MarkdownEditingCommands.wrapMarker(forTyped: typed) {
            let selected = (string as NSString).substring(with: selection)
            let mLen = (marker as NSString).length
            applyEdit(selection, with: marker + selected + marker,
                      cursor: NSRange(location: selection.location + mLen, length: selection.length))
            return
        }

        if typed == "[", selection.length == 0 {
            let ns = string as NSString
            let cursor = selection.location
            if cursor > 0, ns.character(at: cursor - 1) == UInt16(UnicodeScalar("[").value) {
                super.insertText("[", replacementRange: replacementRange) // сам второй «[»
                let pos = selectedRange().location
                applyEdit(NSRange(location: pos, length: 0), with: "]]", cursor: NSRange(location: pos, length: 0))
                return
            }
        }

        super.insertText(insertString, replacementRange: replacementRange)
    }

    /// ⌘B/⌘I через чистую логику wrapToggle.
    private func applyWrapToggle(marker: String) {
        let result = MarkdownEditingCommands.wrapToggle(in: string as NSString, selection: selectedRange(), marker: marker)
        applyEdit(result.range, with: result.replacement, cursor: result.selection)
    }

    /// Правка через shouldChangeText/didChangeText — как ввод с клавиатуры: попадает
    /// в undo, триггерит textDidChange (инкрементальная перекраска + автосейв).
    private func applyEdit(_ range: NSRange, with replacement: String, cursor: NSRange) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(cursor)
    }
}

/// NSTextView-редактор с binding текста и подсветкой. Фокус ставится сам —
/// новая заметка из дерева сразу готова к вводу (критерий задачи 03).
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    /// Открытый файл — по нему отличаем «сменили файл» (курсор в начало) от «тихо
    /// перечитали тот же файл с диска» (сохранить позицию курсора/прокрутки).
    var fileURL: URL? = nil
    /// Цели для автокомплита [[ (имена заметок vault). Зовётся при показе попапа.
    var completionTargets: () -> [String] = { [] }
    /// Переход по wikilink (Cmd+клик): открыть или создать заметку.
    var onWikilinkClick: (String) -> Void = { _ in }

    fileprivate static let baseFontSize: CGFloat = 15

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, completionTargets: completionTargets, onWikilinkClick: onWikilinkClick)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Ручная сборка вместо scrollableTextView(): нужен наш подкласс.
        let textView = MarkdownTextView()
        // Обращение к layoutManager переводит NSTextView в TextKit 1 (на macOS 14+
        // по умолчанию TextKit 2) — до конфигурации контейнера, чтобы он не
        // пересоздался. Делегат скрывает глифы маркеров (см. ConcealingLayoutDelegate).
        textView.layoutManager?.delegate = context.coordinator.concealingDelegate
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
        // Делегат textStorage лишь ЗАПИСЫВАет диапазон правки (pendingEdit) — для
        // инкрементальной подсветки. Ставим ДО заполнения текста.
        textView.textStorage?.delegate = context.coordinator
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

        context.coordinator.lastKnownFileURL = fileURL
        // Плавное открытие: стилизуем строку и ставим concealedRanges ДО первого
        // лэйаута — маркеры свёрнуты с первого кадра, без видимого «прыжка».
        let styled = context.coordinator.buildStyledAttributedString(text)
        textView.textStorage?.setAttributedString(styled)
        context.coordinator.primeConcealment(textView)
        context.coordinator.clearPendingEdit()

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
        let fileChanged = fileURL != context.coordinator.lastKnownFileURL
        context.coordinator.lastKnownFileURL = fileURL
        // Обновляем только при внешней замене текста (открыли другой файл,
        // перечитали с диска) — во время набора string уже совпадает с binding.
        if textView.string != text {
            let savedCaret = textView.selectedRange()
            let savedScrollOrigin = scrollView.contentView.bounds.origin

            let styled = context.coordinator.buildStyledAttributedString(text)
            textView.textStorage?.setAttributedString(styled)
            context.coordinator.primeConcealment(textView)
            context.coordinator.clearPendingEdit()

            // Сменили файл → курсор в начало; тот же файл перечитан → сохранить
            // позицию (заклампив под новую длину) и не дёргать прокрутку.
            let disposition = Coordinator.reloadDisposition(
                fileChanged: fileChanged,
                savedCaret: savedCaret,
                newLength: (text as NSString).length
            )
            textView.setSelectedRange(disposition.caret)
            if disposition.resetScroll {
                textView.scrollToBeginningOfDocument(nil)
            } else {
                scrollView.contentView.scroll(to: savedScrollOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    /// Делегат NSTextView + textStorage: тянет правки в binding, инкрементально
    /// перекрашивает разметку, открывает автокомплит в контексте «[[».
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        private let text: Binding<String>
        var completionTargets: () -> [String]
        var onWikilinkClick: (String) -> Void
        /// Ссылки текущего текста — для Cmd+клика и подсветки. Инкрементально
        /// поддерживается вместе с currentConcealables (rebuiltLinks).
        private var currentLinks: [Wikilink] = []
        /// Все сворачиваемые маркеры текущего текста — свежие после highlight(_:)
        /// и инкрементально пересобираются на каждую правку (rebuiltConcealables);
        /// restyleConcealedRanges переиспользует их без повторного парсинга при
        /// каждом движении курсора.
        private var currentConcealables: [ConcealableMarker] = []
        /// Индексы маркеров, СЕЙЧАС показанных. Ключевой кэш для диффа: на смену
        /// курсора инвалидируем глифы ТОЛЬКО у маркеров, чьё состояние изменилось
        /// (ушёл/зашёл на строку). Иначе полная реинвалидация лэйаута на каждый
        /// клик сбрасывала бы прокрутку наверх.
        private var revealedMarkerIndices: Set<Int> = []
        /// Диапазон последней правки (в НОВЫХ координатах) + изменение длины —
        /// пишет textStorage(_:didProcessEditing:…), применяет textDidChange. nil —
        /// правок символов с прошлой подсветки не было.
        private var pendingEdit: (range: NSRange, delta: Int)?
        /// Открытый файл — чтобы updateNSView отличал смену файла от перезагрузки.
        var lastKnownFileURL: URL?
        /// Делегат layoutManager, скрывающий глифы маркеров (нуллификация). Живёт
        /// на координаторе (retained); NSTextView ссылается на него слабо.
        let concealingDelegate = ConcealingLayoutDelegate()

        /// Порог, выше которого инкрементальный рестайл ограничивается строкой
        /// правки, а не всем абзацем: гигантский одно-блочный абзац (без пустых
        /// строк) иначе снова тормозил бы. Инлайн-разметка однострочна, так что
        /// строчный охват для неё корректен (см. заголовок файла, «мягкий кап»).
        private static let maxIncrementalBlock = 8000

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

            if let edit = pendingEdit {
                pendingEdit = nil
                if needsFullRehighlight(editedRange: edit.range, delta: edit.delta, in: textView) {
                    highlight(textView)                     // структурная правка (```/%%) — полный проход
                } else {
                    highlightIncrementally(textView, editedRange: edit.range, delta: edit.delta)
                }
            } else {
                highlight(textView)                         // нет записи правки — безопасный полный
            }

            // Курсор в незакрытом «[[…» — показать/обновить попап автокомплита.
            if textView.wikilinkQueryRange.location != NSNotFound {
                textView.complete(nil)
            }
        }

        /// ЗАПИСЫВАет диапазон правки — применяет её textDidChange. Атрибуты внутри
        /// processEditing трогать нельзя (сдвигает каретку), поэтому только record.
        /// .editedAttributes (наши же addAttribute) игнорируем — иначе рекурсия.
        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            if let existing = pendingEdit {
                let loc = min(existing.range.location, editedRange.location)
                let end = max(NSMaxRange(existing.range), NSMaxRange(editedRange))
                pendingEdit = (NSRange(location: loc, length: end - loc), existing.delta + delta)
            } else {
                pendingEdit = (editedRange, delta)
            }
        }

        /// Курсор/выделение сдвинулись — разворачиваем свёрнутые маркеры под
        /// курсором, сворачиваем остальные. НЕ гоняет полный regex-скан
        /// документа (тот остаётся только на textDidChange) — только
        /// перекрашивает уже распарсенные диапазоны из currentConcealables,
        /// поэтому на каждое нажатие стрелки не нагружает.
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

        /// Полный проход: перекрашивает и перепарсивает ВЕСЬ документ. Дорогой
        /// (O(N)) — зовётся только на открытии, внешней перезагрузке и структурной
        /// правке (```/%%). Обычные нажатия идут через highlightIncrementally.
        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            storage.beginEditing()
            let (markers, links) = styleRegion(storage, blockText: textView.string, offset: 0, includeMultiBlock: true)
            storage.endEditing()
            currentConcealables = markers
            currentLinks = links
            primeConcealment(textView)
            pendingEdit = nil
        }

        /// Быстрый путь: перекрашивает и перепарсивает ТОЛЬКО блок вокруг правки
        /// (BlockRange.enclosingBlock), маркеры за пределами блока лишь сдвигаются
        /// на изменение длины. Ни полного regex-скана, ни полного релэйаута —
        /// поэтому текст не дёргается при наборе.
        func highlightIncrementally(_ textView: NSTextView, editedRange: NSRange, delta: Int) {
            guard let storage = textView.textStorage, let layoutManager = textView.layoutManager else { return }
            let ns = textView.string as NSString

            var newBlock = BlockRange.enclosingBlock(of: editedRange, in: ns)
            // Мягкий кап: гигантский абзац без пустых строк — ограничиваемся
            // строкой(ами) правки (инлайн-разметка однострочна, так что корректно).
            if newBlock.length > Self.maxIncrementalBlock {
                let startLine = ns.lineRange(for: NSRange(location: min(editedRange.location, max(0, ns.length - 1)), length: 0))
                let endProbe = min(max(NSMaxRange(editedRange), editedRange.location), max(0, ns.length - 1))
                let endLine = ns.lineRange(for: NSRange(location: endProbe, length: 0))
                newBlock = NSUnionRange(startLine, endLine)
            }

            let oldLength = newBlock.length - delta
            guard oldLength >= 0 else { highlight(textView); return } // редкий вырожденный случай
            let oldBlock = NSRange(location: newBlock.location, length: oldLength)

            let blockText = ns.substring(with: newBlock)
            storage.beginEditing()
            let (freshMarkers, freshLinks) = styleRegion(storage, blockText: blockText, offset: newBlock.location, includeMultiBlock: false)
            storage.endEditing()

            currentConcealables = Self.rebuiltConcealables(previous: currentConcealables, oldDirty: oldBlock, delta: delta, fresh: freshMarkers)
            currentLinks = Self.rebuiltLinks(previous: currentLinks, oldDirty: oldBlock, delta: delta, fresh: freshLinks)

            let revealed = Self.revealedIndices(for: textView.selectedRange(), in: currentConcealables, storageLength: storage.length)
            revealedMarkerIndices = revealed
            concealingDelegate.concealedRanges = Self.concealedRanges(from: currentConcealables, revealed: revealed, storageLength: storage.length)

            // Форсируем перегенерацию глифов блока: новые/сломанные маркеры должны
            // пере-свернуться. Только блок — не весь документ (иначе прокрутка бы прыгала).
            layoutManager.invalidateGlyphs(forCharacterRange: newBlock, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: newBlock, actualCharacterRange: nil)
        }

        /// Нужен ли полный проход вместо инкрементального: код-фенс ``` или
        /// %%-комментарий многоблочны и «протекают» за границу блока — их правка
        /// перекрашивает всё после них. См. static-версию (тестируется отдельно).
        func needsFullRehighlight(editedRange: NSRange, delta: Int, in textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let newBlock = BlockRange.enclosingBlock(of: editedRange, in: ns)
            let oldBlock = NSRange(location: newBlock.location, length: max(0, newBlock.length - delta))
            return Self.needsFullRehighlight(newBlockText: ns.substring(with: newBlock), oldDirty: oldBlock, markers: currentConcealables)
        }

        /// Стилизованная строка для плавного открытия: та же стилизация, что
        /// highlight, но в свежий NSMutableAttributedString — ставится в storage до
        /// первого лэйаута (см. makeNSView). Кэширует currentConcealables/Links.
        func buildStyledAttributedString(_ text: String) -> NSMutableAttributedString {
            let storage = NSMutableAttributedString(string: text)
            storage.beginEditing()
            let (markers, links) = styleRegion(storage, blockText: text, offset: 0, includeMultiBlock: true)
            storage.endEditing()
            currentConcealables = markers
            currentLinks = links
            return storage
        }

        /// Ставит concealedRanges/revealedMarkerIndices по currentConcealables и
        /// текущему курсору — вызывается после build/highlight, чтобы маркеры были
        /// свёрнуты уже на первом кадре.
        func primeConcealment(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let revealed = Self.revealedIndices(for: textView.selectedRange(), in: currentConcealables, storageLength: storage.length)
            revealedMarkerIndices = revealed
            concealingDelegate.concealedRanges = Self.concealedRanges(from: currentConcealables, revealed: revealed, storageLength: storage.length)
        }

        /// Сбрасывает запись правки — после программной подмены текста
        /// (setAttributedString), чтобы она не была принята за пользовательскую.
        func clearPendingEdit() { pendingEdit = nil }

        /// Реакция на движение курсора: показывает/скрывает ТОЛЬКО маркеры, чьё
        /// состояние изменилось относительно прошлой позиции курсора. Никакого
        /// regex-скана и — главное — никакой полной реинвалидации: клик/стрелка в
        /// пределах уже-показанной строки или в обычном абзаце = полный no-op,
        /// поэтому прокрутка не дёргается.
        func restyleConcealedRanges(_ textView: NSTextView) {
            guard let storage = textView.textStorage, let layoutManager = textView.layoutManager else { return }
            let length = storage.length
            let newRevealed = Self.revealedIndices(
                for: textView.selectedRange(),
                in: currentConcealables,
                storageLength: length
            )
            guard newRevealed != revealedMarkerIndices else { return }

            concealingDelegate.concealedRanges = Self.concealedRanges(from: currentConcealables, revealed: newRevealed, storageLength: length)

            // Инвалидируем глифы+лэйаут ТОЛЬКО у маркеров, чьё состояние
            // изменилось — делегат перегенерирует их с новой видимостью, остальной
            // документ не трогаем (иначе полная реинвалидация роняла бы прокрутку).
            for i in newRevealed.symmetricDifference(revealedMarkerIndices) where markerFits(i, in: length) {
                for range in currentConcealables[i].hideRanges {
                    layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
                    layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                }
            }
            revealedMarkerIndices = newRevealed
        }

        /// Приглушённый фон код-блоков/инлайн-кода — считается на месте, чтобы
        /// адаптироваться к смене light/dark темы.
        private var codeBackground: NSColor {
            NSColor.textBackgroundColor.blended(withFraction: 0.5, of: .quaternaryLabelColor) ?? .quaternaryLabelColor
        }

        /// Единый движок стилизации одного региона (весь документ для highlight с
        /// offset 0, либо подстрока блока для highlightIncrementally): сброс к базе
        /// → абзацы → разметка → wikilinks → чеклисты → «показанный» вид маркеров.
        /// Парсит регион ОДИН раз и переиспользует для стилизации и для маркеров
        /// (раньше MarkdownHighlighter/WikilinkParser гонялись дважды). Возвращает
        /// маркеры и ссылки в абсолютных координатах (сдвинуты на offset).
        /// - Parameter includeMultiBlock: включать ли %%-комментарии и код-фенсы
        ///   (только для полного прохода — инкрементальный их не трогает, они
        ///   уходят в needsFullRehighlight).
        @discardableResult
        private func styleRegion(
            _ storage: NSMutableAttributedString,
            blockText: String,
            offset: Int,
            includeMultiBlock: Bool
        ) -> (markers: [ConcealableMarker], links: [Wikilink]) {
            let blockNS = blockText as NSString

            applyBaseAttributes(storage, range: NSRange(location: offset, length: blockNS.length))

            for paragraph in ParagraphStyling.paragraphRanges(in: blockText) {
                storage.addAttribute(.paragraphStyle, value: ParagraphStyling.style(for: paragraph.kind), range: shifted(paragraph.range, offset))
            }

            let matches = MarkdownHighlighter.matches(in: blockText)
            styleMarkdownMatches(storage, matches: matches, offset: offset)

            let links = WikilinkParser.parse(blockText)
            styleWikilinks(storage, links: links, offset: offset)

            styleChecklists(storage, items: ChecklistParser.parse(blockText), offset: offset)

            // Маркеры сворачивания — парсим локально, сдвигаем в абсолютные координаты.
            var markers: [ConcealableMarker] = []
            markers += BlockReferenceParser.parse(blockText).map(ConcealableMarker.forBlockReference)
            if includeMultiBlock {
                markers += CommentBlockParser.parse(blockText).map(ConcealableMarker.forCommentBlock)
            }
            markers += links.map(ConcealableMarker.forWikilink)
            markers += matches.flatMap { ConcealableMarker.forHighlighterMatch($0, in: blockNS) }
            markers += ConcealableMarker.forListMarkers(in: blockText)
            let absMarkers = markers.map { $0.shifted(by: offset) }.sorted(by: Self.markerOrder)

            styleShownMarkers(storage, markers: absMarkers)

            let absLinks = links.map { Self.shifted($0, by: offset) }
            return (absMarkers, absLinks)
        }

        /// Сброс региона к базовому шрифту/цвету (setAttributes стирает все прочие
        /// атрибуты — чистый лист перед стилизацией).
        private func applyBaseAttributes(_ storage: NSMutableAttributedString, range: NSRange) {
            guard range.length > 0 else { return }
            storage.setAttributes([
                .font: NSFont.systemFont(ofSize: MarkdownEditorView.baseFontSize),
                .foregroundColor: NSColor.textColor
            ], range: range)
        }

        private func styleMarkdownMatches(_ storage: NSMutableAttributedString, matches: [MarkdownHighlighter.Match], offset: Int) {
            let mono = NSFont.monospacedSystemFont(ofSize: MarkdownEditorView.baseFontSize - 1, weight: .regular)
            for match in matches {
                let range = shifted(match.range, offset)
                switch match.kind {
                case .heading(let level):
                    let size = MarkdownHighlighter.headingFontSize(level: level, base: MarkdownEditorView.baseFontSize)
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: range)
                case .bold:
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: MarkdownEditorView.baseFontSize), range: range)
                case .highlight:
                    // «Маркер»-заливка (Obsidian ==выделение==) — жёлтый адаптируется
                    // к light/dark сам, альфа держит текст читаемым поверх.
                    storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: range)
                case .inlineCode, .codeBlock:
                    storage.addAttribute(.font, value: mono, range: range)
                    storage.addAttribute(.backgroundColor, value: codeBackground, range: range)
                case .blockquote:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                }
            }
        }

        /// Wikilinks — акцентный цвет + подчёркивание; Cmd+клик обрабатывает
        /// MarkdownTextView (атрибут .link не ставим: обычный клик по нему
        /// уводил бы в NSWorkspace вместо позиционирования курсора).
        private func styleWikilinks(_ storage: NSMutableAttributedString, links: [Wikilink], offset: Int) {
            for link in links {
                let range = shifted(link.range, offset)
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        /// Чеклисты: маркер жирный (акцент — незавершён, приглушённый — готов),
        /// текст выполненного пункта зачёркнут и приглушён — как в Obsidian.
        private func styleChecklists(_ storage: NSMutableAttributedString, items: [ChecklistItem], offset: Int) {
            for item in items {
                let markerRange = shifted(item.markerRange, offset)
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: MarkdownEditorView.baseFontSize), range: markerRange)
                storage.addAttribute(
                    .foregroundColor,
                    value: item.isChecked ? NSColor.secondaryLabelColor : NSColor.controlAccentColor,
                    range: markerRange
                )
                if item.isChecked {
                    let contentRange = shifted(item.contentRange, offset)
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: contentRange)
                }
            }
        }

        /// «Показанный» вид маркеров (в абсолютных координатах): приглушённый цвет
        /// (plain) либо моно+фон (codeBlock). Видимость далее регулирует делегат
        /// (нуллификация глифов).
        private func styleShownMarkers(_ storage: NSMutableAttributedString, markers: [ConcealableMarker]) {
            let mono = NSFont.monospacedSystemFont(ofSize: MarkdownEditorView.baseFontSize - 1, weight: .regular)
            let length = storage.length
            for marker in markers {
                for range in marker.hideRanges where NSMaxRange(range) <= length {
                    switch marker.revealStyle {
                    case .plain:
                        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                    case .codeBlock:
                        storage.addAttribute(.font, value: mono, range: range)
                        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                        storage.addAttribute(.backgroundColor, value: codeBackground, range: range)
                    }
                }
            }
        }

        /// Сдвиг диапазона на offset (координаты блока → абсолютные).
        private func shifted(_ range: NSRange, _ offset: Int) -> NSRange {
            BlockRange.shifted(range, by: offset)
        }

        /// Диапазоны, чьи глифы сейчас скрыты: hideRanges всех НЕ показанных
        /// маркеров, отсортированы и слиты (предусловие бинарного поиска в
        /// делегате). Чистая логика — тестируется отдельно.
        static func concealedRanges(from markers: [ConcealableMarker], revealed: Set<Int>, storageLength: Int) -> [NSRange] {
            var ranges: [NSRange] = []
            for (i, marker) in markers.enumerated() where !revealed.contains(i) {
                for range in marker.hideRanges where NSMaxRange(range) <= storageLength {
                    ranges.append(range)
                }
            }
            return ConcealingLayoutDelegate.mergeRanges(ranges)
        }

        /// Какие маркеры должны быть развёрнуты при данной позиции курсора.
        /// Чистая логика (без storage) — сердце диффа, отдельно тестируется по
        /// углам: движение в пределах строки не меняет множество, переход на
        /// другую строку меняет; устаревшие (вне текущих границ) маркеры
        /// исключаются, чтобы не трогать storage за его пределами.
        static func revealedIndices(for caret: NSRange, in markers: [ConcealableMarker], storageLength: Int) -> Set<Int> {
            var result = Set<Int>()
            for (i, marker) in markers.enumerated() {
                guard NSMaxRange(marker.revealTrigger) <= storageLength,
                      marker.hideRanges.allSatisfy({ NSMaxRange($0) <= storageLength }) else { continue }
                if selection(caret, overlaps: marker.revealTrigger) { result.insert(i) }
            }
            return result
        }

        /// Диапазоны маркера укладываются в текущую длину storage. Защищает от
        /// краша, когда кэш ещё держит маркеры от предыдущего (более длинного)
        /// текста между подменой textView.string и re-highlight (см. регрессию).
        private func markerFits(_ index: Int, in storageLength: Int) -> Bool {
            guard index < currentConcealables.count else { return false }
            let marker = currentConcealables[index]
            return marker.hideRanges.allSatisfy { NSMaxRange($0) <= storageLength }
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

        // MARK: - Инкрементальная пересборка кэша (чистая логика — тестируется)

        /// Пересобирает кэш маркеров после локальной правки: маркеры «грязного»
        /// блока (oldDirty, координаты СТАРОГО текста) выброшены — они есть в fresh;
        /// маркеры ПОСЛЕ правки сдвинуты на delta; маркеры до правки не тронуты.
        /// Результат отсортирован по позиции — канонично, равно полному парсу.
        /// Маркеры адресуются по anchor = revealTrigger.location: строки/блоки не
        /// пересекают границу блока (пустую строку), поэтому anchor однозначно
        /// относит маркер к «до / внутри / после» правки.
        static func rebuiltConcealables(previous: [ConcealableMarker], oldDirty: NSRange, delta: Int, fresh: [ConcealableMarker]) -> [ConcealableMarker] {
            let dirtyEnd = NSMaxRange(oldDirty)
            var result: [ConcealableMarker] = []
            for marker in previous {
                let anchor = marker.revealTrigger.location
                if anchor >= dirtyEnd {
                    result.append(marker.shifted(by: delta))     // после правки — сдвиг
                } else if anchor >= oldDirty.location {
                    continue                                     // внутри блока — перепарсен в fresh
                } else {
                    result.append(marker)                        // до правки — без изменений
                }
            }
            result.append(contentsOf: fresh)
            return result.sorted(by: markerOrder)
        }

        /// То же для wikilinks (currentLinks): дроп внутри блока, сдвиг после.
        static func rebuiltLinks(previous: [Wikilink], oldDirty: NSRange, delta: Int, fresh: [Wikilink]) -> [Wikilink] {
            let dirtyEnd = NSMaxRange(oldDirty)
            var result: [Wikilink] = []
            for link in previous {
                let anchor = link.range.location
                if anchor >= dirtyEnd {
                    result.append(shifted(link, by: delta))
                } else if anchor >= oldDirty.location {
                    continue
                } else {
                    result.append(link)
                }
            }
            result.append(contentsOf: fresh)
            return result.sorted { $0.range.location < $1.range.location }
        }

        /// Порядок маркеров: по началу revealTrigger, затем по первому hideRange —
        /// стабильно и канонично (для сравнения с полным парсом в тестах).
        private static func markerOrder(_ a: ConcealableMarker, _ b: ConcealableMarker) -> Bool {
            if a.revealTrigger.location != b.revealTrigger.location {
                return a.revealTrigger.location < b.revealTrigger.location
            }
            return (a.hideRanges.first?.location ?? 0) < (b.hideRanges.first?.location ?? 0)
        }

        /// Копия ссылки со сдвинутыми диапазонами (range + concealShape).
        private static func shifted(_ link: Wikilink, by delta: Int) -> Wikilink {
            guard delta != 0 else { return link }
            func s(_ r: NSRange) -> NSRange { NSRange(location: r.location + delta, length: r.length) }
            return Wikilink(
                range: s(link.range),
                target: link.target,
                heading: link.heading,
                alias: link.alias,
                concealShape: .init(hidePrefix: s(link.concealShape.hidePrefix), hideSuffix: s(link.concealShape.hideSuffix), visible: s(link.concealShape.visible))
            )
        }

        // MARK: - Структурная правка и позиция при перезагрузке (чистая логика)

        /// Нужен ли полный проход: правка вводит/убирает ограничитель код-фенса
        /// ``` или %%-комментария в блоке, ЛИБО попала в/через уже существующий
        /// многоблочный блок (маркер с revealStyle == .codeBlock пересекает
        /// oldDirty — это ровно фенсы и %%-комментарии). Иначе безопасно инкрементально.
        static func needsFullRehighlight(newBlockText: String, oldDirty: NSRange, markers: [ConcealableMarker]) -> Bool {
            if newBlockText.contains("%%") { return true }
            if containsFenceLine(newBlockText) { return true }
            for marker in markers where marker.revealStyle == .codeBlock {
                if oldDirty.length == 0 {
                    if NSLocationInRange(oldDirty.location, marker.revealTrigger) || oldDirty.location == NSMaxRange(marker.revealTrigger) { return true }
                } else if NSIntersectionRange(marker.revealTrigger, oldDirty).length > 0 {
                    return true
                }
            }
            return false
        }

        private static func containsFenceLine(_ text: String) -> Bool {
            text.split(separator: "\n", omittingEmptySubsequences: false).contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            }
        }

        /// Куда ставить курсор и трогать ли прокрутку при внешней замене текста:
        /// сменили файл → в начало и сброс прокрутки; тот же файл перечитан →
        /// сохранить позицию (заклампив под новую длину), прокрутку не трогать.
        static func reloadDisposition(fileChanged: Bool, savedCaret: NSRange, newLength: Int) -> (caret: NSRange, resetScroll: Bool) {
            guard !fileChanged else { return (NSRange(location: 0, length: 0), true) }
            let loc = min(max(savedCaret.location, 0), newLength)
            let len = min(savedCaret.length, max(0, newLength - loc))
            return (NSRange(location: loc, length: len), false)
        }
    }
}
