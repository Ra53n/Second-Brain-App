// FineTuneCriteriaPrompts.swift — чистое ядро генерации criteria.md (задача 83).
//
// Отбор примеров и сборка сообщений LLM без I/O — тестируется без сети и без моков.

import Foundation

enum FineTuneCriteriaPrompts {
    private static let instruction = """
    Ты — редактор качества fine-tuning. По примерам ниже (задание → эталонный ответ \
    автора) составь criteria.md для оценки ответов модели. Документ должен содержать:

    1) Чек-лист из 6–10 проверяемых критериев стиля, структуры и содержания — для \
    каждого коротко поясни, как его проверить на конкретном ответе.
    2) Анти-признаки — чего в ответе быть не должно (штампы, форматирование, интонация, \
    не свойственные автору).
    3) Шкалу оценки ответа от 0 до 8 баллов и порог приемлемости.

    Ответь только Markdown-документом, без преамбулы и заключения от себя.
    """

    /// Равномерный шаг по индексам (без Random) — детерминированная выборка. Если
    /// сумма (user+assistant).count не влезает в бюджет, отбрасываем с конца, но не
    /// ниже одного примера — генерации не бывает без единого образца.
    static func sampleExamples(_ all: [FineTuneExample], limit: Int = 8,
                               charBudget: Int = 24_000) -> [FineTuneExample] {
        guard !all.isEmpty else { return [] }
        let n = min(max(limit, 1), all.count)
        let indices = (0..<n).map { $0 * all.count / n }
        var selected = indices.map { all[$0] }
        while selected.count > 1 && totalChars(selected) > charBudget {
            selected.removeLast()
        }
        return selected
    }

    static func buildMessages(datasetTitle: String, system: String?,
                              examples: [FineTuneExample]) -> [ChatMessageDTO] {
        var userText = ""
        if let system, !system.isEmpty {
            userText += "Системный промпт датасета «\(datasetTitle)»:\n\(system)\n\n"
        }
        for (index, example) in examples.enumerated() {
            userText += "[ПРИМЕР \(index + 1)]\n## Задание\n\(example.user)\n## Эталон\n\(example.assistant)\n\n"
        }
        return [
            ChatMessageDTO(role: .system, content: instruction),
            ChatMessageDTO(role: .user, content: userText.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
    }

    /// Срезает обёртку ```markdown …``` целиком вокруг документа; ```-блоки внутри
    /// текста (документ их может законно цитировать) не трогаются — проверяется
    /// только первая и последняя строка.
    static func postprocess(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6 else { return trimmed }
        guard let firstNewline = trimmed.firstIndex(of: "\n") else { return trimmed }
        trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        trimmed = String(trimmed.dropLast(3))
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func totalChars(_ examples: [FineTuneExample]) -> Int {
        examples.reduce(0) { $0 + $1.user.count + $1.assistant.count }
    }
}
