// RagRerank.swift — чистая логика второго этапа ретрива (порт RagRerank MA):
// порог релевантности, промпты и парсеры query rewrite / LLM-реранка.
//
// Обе опции ВЫКЛЮЧЕНЫ по умолчанию (лишние LLM-вызовы; включаются в
// настройках чата). Здесь нет I/O и LLM — только чистые функции; сами вызовы
// делает RagRetriever. Парсеры терпят ЛЮБОЙ мусор: непарсибельный ответ
// реранкера → nil (фолбэк на порядок по score), кривой rewrite → исходный
// вопрос — ретрив никогда не ломает отправку сообщения.

import Foundation

enum RagRerank {
    // MARK: Порог релевантности (бесплатная эвристика)

    /// Отбрасывает кандидатов ниже порога (порядок сохраняется).
    /// minScore <= 0 — фильтр выключен. Может отбросить всех — это фича:
    /// нерелевантное не подставляем.
    static func thresholdFilter(_ hits: [RagHit], minScore: Double) -> [RagHit] {
        guard minScore > 0 else { return hits }
        return hits.filter { Double($0.score) >= minScore }
    }

    // MARK: Query rewrite

    static let rewriteSystemPrompt = """
    Ты переформулируешь вопрос пользователя в самодостаточный поисковый запрос к базе \
    знаний. Раскрой местоимения и отсылки («он», «эта заметка», «там») по недавнему \
    диалогу, сохрани все ключевые термины, имена и числа. Верни ТОЛЬКО текст запроса \
    одной строкой, без кавычек и пояснений.
    """

    /// user-сообщение для rewrite: последние реплики диалога (усечённые) + вопрос.
    static func rewriteUserPrompt(question: String,
                                  history: [ChatMessage],
                                  maxTurns: Int = 6,
                                  maxTurnChars: Int = 400) -> String {
        var lines: [String] = []
        for message in history.suffix(maxTurns) {
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let role = message.role == .user ? "Пользователь" : "Ассистент"
            lines.append("\(role): \(String(text.prefix(maxTurnChars)))")
        }
        let dialog = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
        return dialog + "Вопрос: \(question)"
    }

    /// Одна строка переписанного запроса: срезает кавычки/служебные префиксы;
    /// пусто или неправдоподобно длинно → fallback. Никогда не бросает.
    static func parseRewrittenQuery(_ text: String, fallback: String, maxChars: Int = 500) -> String {
        guard let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return fallback }
        var query = firstLine
        for prefix in ["Запрос:", "Поисковый запрос:", "Query:"] {
            if query.lowercased().hasPrefix(prefix.lowercased()) {
                query = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let quotes = CharacterSet(charactersIn: "\"'«»`“”")
        query = query.trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, query.count <= maxChars else { return fallback }
        return query
    }

    // MARK: LLM-реранк

    static let rerankSystemPrompt = """
    Ты оцениваешь релевантность фрагментов базы знаний поисковому запросу. Дан ЗАПРОС \
    и пронумерованные ФРАГМЕНТЫ. Выведи номера фрагментов, которые реально помогают \
    ответить на запрос, через запятую в порядке убывания релевантности (например: 3,1,5). \
    Нерелевантные не включай. Если не подходит ни один — выведи ровно 0. Без пояснений.
    """

    /// user-сообщение реранка: запрос + нумерованные кандидаты (усечены —
    /// 20 кандидатов × 600 символов ≈ 4k токенов).
    static func rerankUserPrompt(query: String,
                                 candidates: [String],
                                 maxChunkChars: Int = 600) -> String {
        var out = "ЗАПРОС: \(query)\n\nФРАГМЕНТЫ:\n"
        for (index, text) in candidates.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\(index + 1)) \(String(trimmed.prefix(maxChunkChars)))\n"
        }
        return out
    }

    /// Разбор ответа реранкера:
    ///  - nil — мусор → фолбэк на порядок по score;
    ///  - [] — модель явно ответила «0» (ничего не релевантно);
    ///  - иначе 0-based индексы по убыванию (дедуп, вне диапазона отброшены).
    static func parseRerankIndices(_ text: String, candidateCount: Int) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "0" { return [] }
        var seen = Set<Int>()
        var result: [Int] = []
        for token in trimmed.split(whereSeparator: { !$0.isNumber }) {
            guard let n = Int(token), n >= 1, n <= candidateCount else { continue }
            let index = n - 1
            if seen.insert(index).inserted { result.append(index) }
        }
        return result.isEmpty ? nil : result
    }

    /// Применяет порядок реранка: nil → топ-K по score (фолбэк);
    /// иначе переупорядочить и взять первые topK (пустые indices → пусто).
    static func applyRerank(hits: [RagHit], indices: [Int]?, topK: Int) -> [RagHit] {
        guard let indices else { return Array(hits.prefix(max(0, topK))) }
        let picked = indices.compactMap { $0 >= 0 && $0 < hits.count ? hits[$0] : nil }
        return Array(picked.prefix(max(0, topK)))
    }
}
