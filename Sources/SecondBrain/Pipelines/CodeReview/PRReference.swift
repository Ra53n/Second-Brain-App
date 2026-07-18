// PRReference.swift — парсер ссылки на PR (задача 37).
//
// Принимает две формы: полный URL github.com/{owner}/{repo}/pull/{n}
// (с хвостами вида /files, /commits и query-параметрами) и короткую
// owner/repo#n. Чистые функции — исчерпывающе тестируются без сети.

import Foundation

/// Маркер «итог ревью этого PR» на сообщении чата (задача 37).
typealias ReviewTarget = PRReference

/// Адрес PR: владелец, репозиторий, номер. Codable — в роли ReviewTarget
/// персистится маркером на итоговом сообщении ревью (ChatMessage).
struct PRReference: Equatable, Codable {
    let owner: String
    let repo: String
    let number: Int

    /// nil — строка не похожа ни на одну из поддерживаемых форм.
    static func parse(_ text: String) -> PRReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parseURL(trimmed) ?? parseShort(trimmed)
    }

    /// Первый PR-URL внутри произвольного текста (строка «URL: …» из
    /// payloadText PR-watch) — чтобы не таскать структуру payload'а.
    static func firstMatch(in payload: String) -> PRReference? {
        for rawToken in payload.split(whereSeparator: { $0.isWhitespace }) {
            if let reference = parseURL(String(rawToken)) { return reference }
        }
        return nil
    }

    // MARK: - Формы

    /// https://github.com/{owner}/{repo}/pull/{n}[/files…][?query][#fragment]
    private static func parseURL(_ text: String) -> PRReference? {
        guard let url = URL(string: text),
              let host = url.host, host == "github.com" || host == "www.github.com"
        else { return nil }
        // pathComponents: ["/", owner, repo, "pull", n, …хвост игнорируем]
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull",
              let number = Int(parts[3]), number > 0 else { return nil }
        return PRReference(owner: parts[0], repo: parts[1], number: number)
    }

    /// owner/repo#n — ровно один «/», ровно один «#», номер положительный.
    private static func parseShort(_ text: String) -> PRReference? {
        let hashParts = text.split(separator: "#", omittingEmptySubsequences: false)
        guard hashParts.count == 2, let number = Int(hashParts[1]), number > 0
        else { return nil }
        let pathParts = hashParts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard pathParts.count == 2,
              !pathParts[0].isEmpty, !pathParts[1].isEmpty,
              // Владелец/репо не содержат пробелов и «странных» символов —
              // отсечь мусор вида «а вот 1/2#3 из текста».
              pathParts.allSatisfy({ part in
                  part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
              })
        else { return nil }
        return PRReference(owner: String(pathParts[0]), repo: String(pathParts[1]), number: number)
    }
}
