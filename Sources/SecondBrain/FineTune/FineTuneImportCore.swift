// FineTuneImportCore.swift — разбор импортируемого JSONL и детерминированный сплит
// (P1, без I/O, задача 83).
//
// Критерии валидной строки поверх `FineTuneJSONL.parseExample` (роли/порядок/количество):
// content всех трёх сообщений непустой, а system совпадает с первой валидной строкой —
// иначе `validate.py` завалит датасет расхождением с `system_prompt.txt` позже.

import Foundation

enum FineTuneImportCore {
    struct ParsedExample: Equatable {
        let rawLine: String
        let system: String
        let user: String
        let assistant: String
    }

    struct ParseIssue: Equatable {
        let line: Int
        let reason: String
    }

    struct ParseResult: Equatable {
        var examples: [ParsedExample] = []
        var issues: [ParseIssue] = []
    }

    private static let reservedNames: Set<String> = [
        "data", "runs", "adapters", "baseline", "tuned", "corpus", "__pycache__"
    ]

    /// Построчно; пустые строки пропускаются молча, номер строки — 1-based по файлу.
    static func parse(text: String) -> ParseResult {
        var result = ParseResult()
        var canonicalSystem: String?

        for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let lineNumber = offset + 1
            guard !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            guard let body = FineTuneJSONL.parseExample(line: rawLine) else {
                result.issues.append(ParseIssue(line: lineNumber, reason: invalidStructureReason(rawLine)))
                continue
            }
            let system = body.system.trimmingCharacters(in: .whitespacesAndNewlines)
            let user = body.user.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistant = body.assistant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !system.isEmpty, !user.isEmpty, !assistant.isEmpty else {
                result.issues.append(ParseIssue(line: lineNumber, reason: "пустой content"))
                continue
            }
            if let canonicalSystem, body.system != canonicalSystem {
                result.issues.append(ParseIssue(line: lineNumber, reason: "system отличается от первого примера"))
                continue
            }
            canonicalSystem = canonicalSystem ?? body.system
            result.examples.append(ParsedExample(rawLine: rawLine, system: body.system,
                                                 user: body.user, assistant: body.assistant))
        }
        return result
    }

    /// `FineTuneJSONL.parseExample` не различает причину отказа — здесь только
    /// диагностика (не JSON vs не тот набор ролей), решение о валидности остаётся за ним.
    private static func invalidStructureReason(_ line: String) -> String {
        struct DiagMessage: Decodable { let role: String? }
        struct DiagLine: Decodable { let messages: [DiagMessage]? }

        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(DiagLine.self, from: data),
              let messages = decoded.messages
        else { return "не JSON" }

        guard messages.count == 3,
              messages[0].role == "system", messages[1].role == "user", messages[2].role == "assistant"
        else { return "ожидаются ровно три сообщения system/user/assistant" }

        return "не JSON"
    }

    /// Детерминированный шафл (SplitMix64 — `SystemRandomNumberGenerator` не сидируется)
    /// + разрез; при count >= 2 гарантированы минимум 1 valid и минимум 1 train.
    static func split(count: Int, evalFraction: Double = 0.2, seed: UInt64) -> (train: [Int], valid: [Int]) {
        guard count > 0 else { return ([], []) }
        var rng = SplitMix64(seed: seed)
        let shuffled = Array(0..<count).shuffled(using: &rng)

        var validCount = Int((Double(count) * evalFraction).rounded())
        if count >= 2 {
            validCount = min(max(validCount, 1), count - 1)
        } else {
            validCount = 0
        }
        let valid = shuffled.prefix(validCount).sorted()
        let train = shuffled.suffix(from: validCount).sorted()
        return (train: train, valid: valid)
    }

    static func syntheticMetaLine(index: Int) -> String {
        let id = String(format: "ex-%04d", index)
        return "{\"id\":\"\(id)\",\"source_post\":\"\(id)\",\"task_type\":\"imported\"}"
    }

    /// Только `[A-Za-z0-9_-]`, непустое, не из зарезервированных имён тулчейна
    /// (без учёта регистра) — иначе датасет наложился бы на служебный каталог.
    static func sanitizeName(_ raw: String) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let cleaned = String(raw.unicodeScalars.filter { allowed.contains($0) })
        guard !cleaned.isEmpty, !reservedNames.contains(cleaned.lowercased()) else { return nil }
        return cleaned
    }

    private struct SplitSummaryPayload: Encodable {
        struct Counts: Encodable { let train: Int; let valid: Int }
        let seed: Int
        let evalFractionTarget: Double
        let evalPosts: [String]
        let counts: Counts

        enum CodingKeys: String, CodingKey {
            case seed
            case evalFractionTarget = "eval_fraction_target"
            case evalPosts = "eval_posts"
            case counts
        }
    }

    /// Формат `split.json` (см. `FineTuneSplitInfo`); `eval_posts` пуст — импорт не
    /// знает про `source_post` (это поле build_dataset.py, не messages-JSONL).
    static func splitSummary(seed: UInt64, trainCount: Int, validCount: Int, evalFraction: Double) -> Data {
        let payload = SplitSummaryPayload(seed: Int(truncatingIfNeeded: seed), evalFractionTarget: evalFraction,
                                          evalPosts: [], counts: .init(train: trainCount, valid: validCount))
        return (try? JSONEncoder().encode(payload)) ?? Data()
    }
}

/// `SystemRandomNumberGenerator` не принимает seed — нужен детерминизм («один seed →
/// один результат» для сплита датасета) без внешней зависимости.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
