// OutputEgressGuard.swift — детерминированный слой 3 задачи 100: обезвреживает
// внешние markdown-картинки/ссылки в ОТВЕТЕ ассистента, способные вынести
// данные (картинка автозагружается рендерером — эксфильтрация без клика
// пользователя; ссылка с query/userinfo/длинным хвостом — типичный маячок).
// Чистая функция без I/O (P1): гейт по promptSecurityEnabled — на стороне вызова.

import Foundation

enum OutputEgressGuard {
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
    /// Отрицательный lookbehind на `!` отделяет ссылки от картинок — те уже
    /// обработаны отдельным проходом.
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"(?<!!)\[([^\]]*)\]\(([^)]+)\)"#)
    private static let base64TailPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9+/=_-]+$"#)

    /// `allowedHosts` — хосты, которые пользователь сам называл в диалоге
    /// (нижний регистр); localhost/127.0.0.1 не считаются внешними.
    /// Fenced-код (```...```) не трогаем: URL внутри примера — данные, не
    /// автозагрузка.
    static func neutralize(_ text: String, allowedHosts: Set<String>) -> String {
        guard !text.isEmpty else { return text }
        let segments = text.components(separatedBy: "```")
        return segments.enumerated().map { index, segment in
            index % 2 == 1 ? segment : neutralizeSegment(segment, allowedHosts: allowedHosts)
        }.joined(separator: "```")
    }

    private static func neutralizeSegment(_ segment: String, allowedHosts: Set<String>) -> String {
        let withoutImages = replaceMatches(in: segment, pattern: imagePattern) { _, rawParen in
            guard let components = externalURLComponents(rawParen),
                  let host = blockedHost(components, allowedHosts: allowedHosts)
            else { return nil }
            return "[внешняя картинка заблокирована: \(host)]"
        }
        return replaceMatches(in: withoutImages, pattern: linkPattern) { linkText, rawParen in
            guard let components = externalURLComponents(rawParen),
                  let host = blockedHost(components, allowedHosts: allowedHosts),
                  carriesData(components)
            else { return nil }
            return "\(linkText) (внешняя ссылка заблокирована: \(host))"
        }
    }

    /// Разбирает `(url)` / `(url "title")` / `(<url>)` — берёт только URL;
    /// только http/https (относительные пути, `mailto:`, якоря `#...` — не наш
    /// случай). CommonMark допускает угловые скобки вокруг адреса: снимаем их,
    /// иначе `![x](<http://evil/…>)` обошёл бы фильтр, а рендерер загрузил бы.
    private static func externalURLComponents(_ rawParen: String) -> URLComponents? {
        var token = rawParen.split(separator: " ", maxSplits: 1).first.map(String.init) ?? rawParen
        token = token.trimmingCharacters(in: .whitespaces)
        if token.hasPrefix("<") { token.removeFirst() }
        if token.hasSuffix(">") { token.removeLast() }
        guard let components = URLComponents(string: token),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return components
    }

    private static func blockedHost(_ components: URLComponents, allowedHosts: Set<String>) -> String? {
        guard let host = components.host?.lowercased(),
              host != "localhost", host != "127.0.0.1",
              !allowedHosts.contains(host)
        else { return nil }
        return host
    }

    /// «Данные в URL»: query-параметры, userinfo (`user@host`), длинный путь
    /// или base64/hex-хвост сегмента пути — типичные каналы эксфильтрации.
    private static func carriesData(_ components: URLComponents) -> Bool {
        if let query = components.percentEncodedQuery, !query.isEmpty { return true }
        if components.percentEncodedUser != nil { return true }
        let path = components.percentEncodedPath
        if path.count > 40 { return true }
        if let tail = path.split(separator: "/").last, tail.count > 24 {
            let range = NSRange(tail.startIndex..<tail.endIndex, in: tail)
            if base64TailPattern.firstMatch(in: String(tail), range: range) != nil { return true }
        }
        return false
    }

    /// Прогоняет `pattern` по `text`, заменяя матчи, для которых `transform`
    /// вернул небезопасную версию (nil — оставить как есть). Строится вперёд по
    /// исходной строке — без проблем со сдвигом диапазонов при мутации на лету.
    private static func replaceMatches(in text: String, pattern: NSRegularExpression,
                                       transform: (_ altOrText: String, _ rawParen: String) -> String?
    ) -> String {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var output = ""
        var lastEnd = 0
        for match in matches where match.numberOfRanges >= 3 {
            let range = match.range
            guard range.location >= lastEnd else { continue }
            output += ns.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
            let altOrText = ns.substring(with: match.range(at: 1))
            let rawParen = ns.substring(with: match.range(at: 2))
            output += transform(altOrText, rawParen) ?? ns.substring(with: range)
            lastEnd = range.location + range.length
        }
        output += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return output
    }
}
