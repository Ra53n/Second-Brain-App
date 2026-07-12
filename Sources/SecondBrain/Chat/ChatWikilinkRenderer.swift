// ChatWikilinkRenderer.swift — [[wikilinks]] в сообщениях чата (задача 14).
//
// Markdown-рендер (MarkdownUI) не знает синтаксиса [[…]], поэтому перед
// показом ссылки конвертируются в обычные markdown-ссылки со схемой
// sbwiki://open?target=… — клик ловится через OpenURLAction и открывает
// заметку в разделе «Заметки». Цитаты-«галлюцинации» (ссылка на
// несуществующую заметку) валидируются резолвером задачи 04 и рендерятся
// перечёркнутым текстом со значком — не кликабельны, пользователь видит враньё.

import Foundation

enum ChatWikilinkRenderer {
    static let scheme = "sbwiki"

    /// Конвертирует [[target|alias]] в markdown: резолвится → ссылка
    /// sbwiki://, нет → перечёркнутый текст с ⚠︎ (галлюцинация модели).
    static func render(_ content: String, resolves: (String) -> Bool) -> String {
        let links = WikilinkParser.parse(content)
        guard !links.isEmpty else { return content }
        let ns = content as NSString
        var result = ""
        var cursor = 0
        for link in links {
            result += ns.substring(with: NSRange(location: cursor,
                                                 length: link.range.location - cursor))
            let display = link.alias ?? link.target
            if resolves(link.target), let url = url(for: link.target) {
                result += "[\(display)](\(url))"
            } else {
                result += "~~\(display)~~ ⚠︎"
            }
            cursor = link.range.location + link.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// sbwiki://open?target=<percent-encoded> для цели wikilink.
    static func url(for target: String) -> String? {
        guard let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return "\(scheme)://open?target=\(encoded)"
    }

    /// Обратный разбор цели из URL клика; nil — не наша схема.
    static func target(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "target" })?.value
        else { return nil }
        return target
    }

    /// Все цели [[wikilinks]] из текста ответа (для валидации цитат).
    static func targets(in content: String) -> [String] {
        WikilinkParser.parse(content).map(\.target)
    }
}
