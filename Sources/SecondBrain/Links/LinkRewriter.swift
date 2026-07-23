// LinkRewriter.swift — переписывание сегмента цели у [[ссылок]] при переименовании заметки (задача 54).

import Foundation

enum LinkRewriter {
    /// Переписывает сегмент цели у всех [[ссылок]], чья цель (регистронезависимо)
    /// входит в `oldTargets` — точные строки target из `backlinks(to:)`, где резолв
    /// уже сделан индексом. `newBaseName` — новое имя без папки и расширения.
    /// Сохраняет папку-префикс, #heading, |alias и пробелы. Возвращает исходный
    /// текст без изменений, если менять нечего.
    static func rewrite(in text: String, oldTargets: Set<String>, newBaseName: String) -> String {
        let toRewrite = WikilinkParser.parse(text).filter { oldTargets.contains($0.target.lowercased()) }
        guard !toRewrite.isEmpty else { return text }

        let ns = text as NSString
        let replaceRanges = toRewrite.map { link -> NSRange in
            // Путь «папка/Имя» — меняем только последний компонент после «/».
            let slash = ns.range(of: "/", options: .backwards, range: link.targetRange)
            guard slash.location != NSNotFound else { return link.targetRange }
            return NSRange(location: NSMaxRange(slash), length: NSMaxRange(link.targetRange) - NSMaxRange(slash))
        }

        let mutable = NSMutableString(string: text)
        // Справа налево — иначе замены разной длины сдвигают диапазоны левее нетронутых.
        for range in replaceRanges.sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: range, with: newBaseName)
        }
        return mutable as String
    }
}
