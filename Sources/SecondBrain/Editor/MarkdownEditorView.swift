// MarkdownEditorView.swift — редактор заметки: NSTextView + лёгкая подсветка markdown.
//
// Здесь живут:
//  - MarkdownHighlighter  — поиск диапазонов разметки (заголовки, жирный, код…);
//                           чистая логика, покрыта тестами;
//  - MarkdownEditorView   — NSViewRepresentable над NSTextView.
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

/// NSTextView-редактор с binding текста и подсветкой. Фокус ставится сам —
/// новая заметка из дерева сразу готова к вводу (критерий задачи 03).
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String

    private static let baseFontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

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

        textView.string = text
        Coordinator.highlight(textView)

        // Курсор сразу в тексте: окно может ещё собираться — через async.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Обновляем только при внешней замене текста (открыли другой файл,
        // перечитали с диска) — во время набора string уже совпадает с binding.
        if textView.string != text {
            textView.string = text
            Coordinator.highlight(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    /// Делегат NSTextView: тянет правки в binding и перекрашивает разметку.
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            Self.highlight(textView)
        }

        /// Красит текст по диапазонам MarkdownHighlighter: сброс к базовому
        /// стилю + атрибуты поверх. Содержимое не меняется — только атрибуты.
        static func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let base = NSFont.systemFont(ofSize: baseFontSize)
            let mono = NSFont.monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular)
            let full = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.setAttributes([
                .font: base,
                .foregroundColor: NSColor.textColor
            ], range: full)

            for match in MarkdownHighlighter.matches(in: textView.string) {
                switch match.kind {
                case .heading(let level):
                    let size = MarkdownHighlighter.headingFontSize(level: level, base: baseFontSize)
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: match.range)
                case .bold:
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseFontSize), range: match.range)
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
            storage.endEditing()
        }

        private static let baseFontSize: CGFloat = MarkdownEditorView.baseFontSize
    }
}
