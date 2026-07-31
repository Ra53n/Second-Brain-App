// FineTuneOutputsReader.swift — разбор снятых baseline/tuned-ответов (P1, чистое ядро).
//
// Два формата outputs.json (новый — объект с метаданными прогона и results:[{id,text}];
// старый — плоский список [{id,text}]) и два поколения .md (свежие: "## Вход" и строка
// про провайдера; закоммиченные: "## Задание" и "- исходный пост:"). Разделение тела по
// "^## " безопасно — "###"-подзаголовки внутри ответов не совпадают с этим префиксом.

import Foundation

enum FineTuneOutputsReader {
    struct Meta: Equatable {
        let provider: String?
        let model: String?
        let adapter: String?
        let temperature: Double?
    }

    struct Answer: Identifiable, Equatable {
        let id: String
        let index: Int
        let taskType: String?
        let input: String
        let output: String
        let reference: String
    }

    struct Snapshot: Equatable {
        let meta: Meta
        let answers: [Answer]
        let textsOnly: [String: String]
    }

    private struct NewOutputsDocument: Decodable {
        struct Entry: Decodable { let id: String; let text: String }
        let provider: String?
        let model: String?
        let adapter: String?
        let temperature: Double?
        let results: [Entry]
    }

    private struct OldOutputsEntry: Decodable { let id: String; let text: String }

    private static let filenamePattern = try! NSRegularExpression(pattern: "^(\\d+)-(.+)\\.md$")
    private static let taskTypePattern = try! NSRegularExpression(pattern: "тип задания: `([^`]+)`")

    static func parseOutputs(json: Data) -> (meta: Meta, texts: [String: String])? {
        let decoder = JSONDecoder()
        if let doc = try? decoder.decode(NewOutputsDocument.self, from: json) {
            let texts = Dictionary(doc.results.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
            return (Meta(provider: doc.provider, model: doc.model, adapter: doc.adapter, temperature: doc.temperature), texts)
        }
        if let entries = try? decoder.decode([OldOutputsEntry].self, from: json) {
            let texts = Dictionary(entries.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
            return (Meta(provider: nil, model: nil, adapter: nil, temperature: nil), texts)
        }
        return nil
    }

    /// name — "%02d-<id>.md"; id может содержать дефисы (uuid), поэтому индекс отрезается
    /// только по первому дефису.
    static func parseAnswerFile(name: String, content: String) -> Answer? {
        let nameRange = NSRange(name.startIndex..., in: name)
        guard let match = filenamePattern.firstMatch(in: name, range: nameRange),
              let indexRange = Range(match.range(at: 1), in: name),
              let idRange = Range(match.range(at: 2), in: name),
              let index = Int(name[indexRange])
        else { return nil }

        let sections = parseSections(content)
        guard let output = sections["Ответ модели"], let reference = sections["Эталон (текст автора)"] else {
            return nil
        }
        let input = sections["Вход"] ?? sections["Задание"] ?? ""
        let contentRange = NSRange(content.startIndex..., in: content)
        let taskType = taskTypePattern.firstMatch(in: content, range: contentRange)
            .flatMap { Range($0.range(at: 1), in: content) }
            .map { String(content[$0]) }

        return Answer(id: String(name[idRange]), index: index, taskType: taskType,
                      input: input, output: output, reference: reference)
    }

    /// Секции по заголовкам "## …"; тело — строки до следующего такого заголовка.
    private static func parseSections(_ content: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentTitle: String?
        var currentBody: [String] = []

        func flush() {
            guard let title = currentTitle else { return }
            sections[title] = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3))
                currentBody = []
            } else if currentTitle != nil {
                currentBody.append(line)
            }
        }
        flush()
        return sections
    }
}
