// FineTuneValidationParser.swift — разбор вывода finetune/validate.py (P1, чистое ядро).
//
// Контракт скрипта: заметки в stdout, ошибки в stderr (заголовок "ОШИБКИ (N):" + строки
// с отступом "  "), код 0/1. isValid решает код возврата, а не наличие строки "OK".

import Foundation

enum FineTuneValidationParser {
    struct Issue: Equatable {
        let file: String?
        let line: Int?
        let text: String
    }

    struct Result: Equatable {
        let isValid: Bool
        let notes: [String]
        let issues: [Issue]
    }

    private static let okLine = "OK — датасет валиден"
    private static let issuesHeaderPrefix = "ОШИБКИ ("

    static func parse(status: Int32, stdout: String, stderr: String) -> Result {
        let notes = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != okLine }
        return Result(isValid: status == 0, notes: notes, issues: parseIssues(stderr))
    }

    private static func parseIssues(_ stderr: String) -> [Issue] {
        stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(issuesHeaderPrefix) }
            .map(parseIssue)
    }

    /// Формат строки — "<where>: <текст>", где where — "файл:строка", голый путь или
    /// служебное слово ("split"). Двоеточия внутри текста не трогаем: число сразу после
    /// первого двоеточия — единственный признак номера строки.
    private static func parseIssue(_ line: String) -> Issue {
        guard let firstColon = line.firstIndex(of: ":") else {
            return Issue(file: nil, line: nil, text: line)
        }
        let head = String(line[line.startIndex..<firstColon])
        let rest = String(line[line.index(after: firstColon)...]).trimmingCharacters(in: .whitespaces)

        if let secondColon = rest.firstIndex(of: ":"), let lineNumber = Int(rest[rest.startIndex..<secondColon]) {
            let text = String(rest[rest.index(after: secondColon)...]).trimmingCharacters(in: .whitespaces)
            return Issue(file: head, line: lineNumber, text: text)
        }
        guard head.contains("/") || head.contains(".") else {
            return Issue(file: nil, line: nil, text: rest)
        }
        return Issue(file: head, line: nil, text: rest)
    }
}
