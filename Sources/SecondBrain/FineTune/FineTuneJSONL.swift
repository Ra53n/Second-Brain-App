// FineTuneJSONL.swift — разбор строк train/valid.jsonl и sidecar-метаданных (P1, без I/O).

import Foundation

enum FineTuneJSONL {
    struct Body: Equatable {
        let system: String
        let user: String
        let assistant: String
    }

    private struct Message: Decodable { let role: String; let content: String }
    private struct Line: Decodable { let messages: [Message] }

    /// Строго три сообщения `system, user, assistant` в этом порядке — иначе nil.
    static func parseExample(line: String) -> Body? {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Line.self, from: data),
              decoded.messages.count == 3,
              decoded.messages[0].role == "system",
              decoded.messages[1].role == "user",
              decoded.messages[2].role == "assistant"
        else { return nil }
        return Body(system: decoded.messages[0].content,
                    user: decoded.messages[1].content,
                    assistant: decoded.messages[2].content)
    }

    static func parseMeta(line: String) -> FineTuneExampleMeta? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FineTuneExampleMeta.self, from: data)
    }
}
