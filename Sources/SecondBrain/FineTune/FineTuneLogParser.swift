// FineTuneLogParser.swift — строка лога mlx-lm → точка прогресса (P1, без I/O).
//
// Val- и train-строки обе начинаются "Iter N:" — val проверяется первым, иначе
// "Val loss" ошибочно попал бы под более широкий train-шаблон. Резка текста и
// по \n, и по \r: tqdm-прогрессбары дописываются в ту же физическую строку.

import Foundation

enum FineTuneLogParser {
    private static let valPattern = try! NSRegularExpression(
        pattern: #"Iter\s+(\d+):\s+Val loss\s+([\d.]+)"#, options: .caseInsensitive)
    private static let trainPattern = try! NSRegularExpression(
        pattern: #"Iter\s+(\d+):\s+Train loss\s+([\d.]+).*?It/sec\s+([\d.]+)"#, options: .caseInsensitive)
    private static let peakMemPattern = try! NSRegularExpression(
        pattern: #"Peak mem\s+([\d.]+)\s+GB"#, options: .caseInsensitive)

    static func parse(line: String) -> FineTuneProgressPoint? {
        let range = NSRange(line.startIndex..., in: line)
        if let match = valPattern.firstMatch(in: line, range: range),
           let iter = intGroup(match, 1, in: line), let loss = doubleGroup(match, 2, in: line) {
            return FineTuneProgressPoint(iter: iter, kind: .val, loss: loss,
                                         itPerSec: nil, peakMemGB: peakMem(in: line))
        }
        if let match = trainPattern.firstMatch(in: line, range: range),
           let iter = intGroup(match, 1, in: line), let loss = doubleGroup(match, 2, in: line),
           let itPerSec = doubleGroup(match, 3, in: line) {
            return FineTuneProgressPoint(iter: iter, kind: .train, loss: loss,
                                         itPerSec: itPerSec, peakMemGB: peakMem(in: line))
        }
        return nil
    }

    static func points(in text: String) -> [FineTuneProgressPoint] {
        splitLines(text).compactMap(parse(line:))
    }

    /// Последние `limit` непустых строк живого лога, без tqdm-прогрессбаров и дублей подряд.
    static func displayLines(in text: String, limit: Int) -> [String] {
        var result: [String] = []
        for raw in splitLines(text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !isProgressBar(line), line != result.last else { continue }
            result.append(line)
        }
        return Array(result.suffix(limit))
    }

    private static func isProgressBar(_ line: String) -> Bool {
        line.contains("it/s]") || line.contains("%|")
    }

    private static func splitLines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
    }

    private static func peakMem(in line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = peakMemPattern.firstMatch(in: line, range: range) else { return nil }
        return doubleGroup(match, 1, in: line)
    }

    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> Int? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return Int(line[range])
    }

    private static func doubleGroup(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> Double? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return Double(line[range])
    }
}
