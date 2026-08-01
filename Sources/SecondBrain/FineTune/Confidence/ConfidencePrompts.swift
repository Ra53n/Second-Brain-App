// ConfidencePrompts.swift — промпты scoring/self-check + толерантные парсеры (задача 85).
//
// Модель натаскана на единственный формат ответа (строгий {"action_items": [...]}) и может
// не ответить по контракту этих отдельных промптов — парсеры вырезают первый JSON-объект
// из текста, при неудаче падают на регекс-фоллбэк; полный провал — nil («сигнал недоступен»).

import Foundation

struct ScoringSignal: Equatable {
    let status: String?
    let confidence: Int?
}

struct SelfCheckSignal: Equatable {
    let supported: [Bool]
    let reasons: [String]
    let missed: Bool
}

enum ConfidencePrompts {
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b([0-9]{1,2}|100)\b"#)

    static func scoringPrompt(transcript: String, answer: String) -> String {
        """
        Ты только что извлёк(ла) поручения из фрагмента встречи. Оцени свой ответ.

        Фрагмент встречи:
        \(transcript)

        Твой ответ:
        \(answer)

        Ответь СТРОГО одним JSON-объектом без пояснений и без ```-обёртки:
        {"status": "OK"|"UNSURE"|"FAIL", "confidence": <целое 0-100>}
        """
    }

    static func selfCheckPrompt(transcript: String, answer: String) -> String {
        """
        Проверь свой ответ на извлечение поручений по фрагменту встречи ниже.

        Фрагмент встречи:
        \(transcript)

        Твой ответ:
        \(answer)

        Для каждого поручения из ответа (в том же порядке) укажи, подтверждено ли оно
        текстом фрагмента. Отдельно укажи, есть ли во фрагменте поручение, пропущенное
        в ответе. Ответь СТРОГО одним JSON-объектом без пояснений и без ```-обёртки:
        {"items": [{"supported": true|false, "reason": "…"}, ...], "missed": true|false}
        """
    }

    static func parseScoring(_ raw: String) -> ScoringSignal? {
        if let object = extractFirstJSONObject(raw) {
            let status = object["status"] as? String
            let confidence = intValue(object["confidence"])
            if status != nil || confidence != nil {
                return ScoringSignal(status: status, confidence: confidence)
            }
        }
        guard let confidence = fallbackConfidence(in: raw) else { return nil }
        return ScoringSignal(status: nil, confidence: confidence)
    }

    static func parseSelfCheck(_ raw: String, expectedCount: Int) -> SelfCheckSignal? {
        guard let object = extractFirstJSONObject(raw), let itemsRaw = object["items"] as? [Any] else { return nil }
        var supported: [Bool] = []
        var reasons: [String] = []
        for element in itemsRaw {
            guard let dict = element as? [String: Any] else { continue }
            supported.append(boolValue(dict["supported"]) ?? false)
            reasons.append((dict["reason"] as? String) ?? "")
        }
        let missed = boolValue(object["missed"]) ?? false
        return SelfCheckSignal(supported: supported, reasons: reasons, missed: missed)
    }

    /// Баланс фигурных скобок с учётом строковых литералов (кавычки/экранирование) —
    /// иначе `}` внутри `"reason"` рвёт вырезание раньше времени.
    private static func extractFirstJSONObject(_ raw: String) -> [String: Any]? {
        let chars = Array(raw)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var end: Int?
        for index in start..<chars.count {
            let char = chars[index]
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
                continue
            }
            switch char {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { end = index }
            default: break
            }
            if end != nil { break }
        }
        guard let end, let data = String(chars[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return Bool(string) }
        return nil
    }

    private static func fallbackConfidence(in raw: String) -> Int? {
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = numberRegex.firstMatch(in: raw, range: range),
              let matchRange = Range(match.range, in: raw) else { return nil }
        return Int(raw[matchRange])
    }
}
