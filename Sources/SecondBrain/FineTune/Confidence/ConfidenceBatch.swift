// ConfidenceBatch.swift — детерминированная подборка примеров и рендер Markdown-отчётов
// батч-прогона (задача 85).

import Foundation

struct BatchItem: Equatable {
    let index: Int
    let transcript: String
    let reference: String
    let kind: String
}

struct BatchRow: Equatable, Codable {
    var index: Int
    var kind: String
    var verdict: ConfidenceVerdict
    var checksPassed: Int
    var checksTotal: Int
    var redundancy: RedundancyAgreement?
    var scoringStatus: String?
    var scoringConfidence: Int?
    var primaryLatency: TimeInterval
    var totalLatency: TimeInterval
    var promptTokens: Int
    var completionTokens: Int
    var extraCalls: Int

    init(index: Int, kind: String, verdict: ConfidenceVerdict, checksPassed: Int, checksTotal: Int,
         redundancy: RedundancyAgreement? = nil, scoringStatus: String? = nil, scoringConfidence: Int? = nil,
         primaryLatency: TimeInterval = 0, totalLatency: TimeInterval = 0,
         promptTokens: Int = 0, completionTokens: Int = 0, extraCalls: Int = 0) {
        self.index = index
        self.kind = kind
        self.verdict = verdict
        self.checksPassed = checksPassed
        self.checksTotal = checksTotal
        self.redundancy = redundancy
        self.scoringStatus = scoringStatus
        self.scoringConfidence = scoringConfidence
        self.primaryLatency = primaryLatency
        self.totalLatency = totalLatency
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.extraCalls = extraCalls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        verdict = try container.decodeIfPresent(ConfidenceVerdict.self, forKey: .verdict) ?? .unsure
        checksPassed = try container.decodeIfPresent(Int.self, forKey: .checksPassed) ?? 0
        checksTotal = try container.decodeIfPresent(Int.self, forKey: .checksTotal) ?? 0
        redundancy = try container.decodeIfPresent(RedundancyAgreement.self, forKey: .redundancy)
        scoringStatus = try container.decodeIfPresent(String.self, forKey: .scoringStatus)
        scoringConfidence = try container.decodeIfPresent(Int.self, forKey: .scoringConfidence)
        primaryLatency = try container.decodeIfPresent(TimeInterval.self, forKey: .primaryLatency) ?? 0
        totalLatency = try container.decodeIfPresent(TimeInterval.self, forKey: .totalLatency) ?? 0
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        extraCalls = try container.decodeIfPresent(Int.self, forKey: .extraCalls) ?? 0
    }
}

enum ConfidenceBatch {

    /// 10 с непустым эталоном + 5 с пустым — равномерный шаг по своим пулам (как
    /// `FineTuneCriteriaPrompts.sampleExamples`); 5 «шумных» — самые длинные транскрипты
    /// из оставшихся. Меньше данных в пуле — берём сколько есть, без падения.
    static func plan(examples: [(index: Int, transcript: String, reference: String)]) -> [BatchItem] {
        var nonEmptyPool: [(index: Int, transcript: String, reference: String)] = []
        var emptyPool: [(index: Int, transcript: String, reference: String)] = []
        var otherPool: [(index: Int, transcript: String, reference: String)] = []

        for example in examples {
            if let items = ActionItemsParser.parse(example.reference) {
                if items.isEmpty { emptyPool.append(example) } else { nonEmptyPool.append(example) }
            } else {
                otherPool.append(example)
            }
        }

        let selectedNonEmpty = evenStep(nonEmptyPool, count: 10)
        let selectedEmpty = evenStep(emptyPool, count: 5)
        let selectedIndices = Set((selectedNonEmpty + selectedEmpty).map(\.index))
        let noisy = (nonEmptyPool + emptyPool + otherPool)
            .filter { !selectedIndices.contains($0.index) }
            .sorted { $0.transcript.count > $1.transcript.count }
            .prefix(5)

        return selectedNonEmpty.map { BatchItem(index: $0.index, transcript: $0.transcript, reference: $0.reference, kind: "непустой") }
            + selectedEmpty.map { BatchItem(index: $0.index, transcript: $0.transcript, reference: $0.reference, kind: "пустой") }
            + noisy.map { BatchItem(index: $0.index, transcript: $0.transcript, reference: $0.reference, kind: "шумный") }
    }

    static func renderReport(title: String, rows: [BatchRow]) -> String {
        var lines = ["# \(title)", "",
                     "| № | тип | вердикт | проверок пройдено | redundancy | scoring | latency осн./полная | токены |",
                     "|---|---|---|---|---|---|---|---|"]
        for row in rows {
            let scoring = [row.scoringStatus, row.scoringConfidence.map(String.init)]
                .compactMap { $0 }.joined(separator: " / ")
            lines.append("| \(row.index) | \(row.kind) | \(row.verdict.rawValue) | "
                + "\(row.checksPassed)/\(row.checksTotal) | \(row.redundancy?.rawValue ?? "—") | "
                + "\(scoring.isEmpty ? "—" : scoring) | "
                + String(format: "%.2fс / %.2fс", row.primaryLatency, row.totalLatency) + " | "
                + "\(row.promptTokens)+\(row.completionTokens) |")
        }

        let total = rows.count
        let failCount = rows.filter { $0.verdict == .fail }.count
        let unsureCount = rows.filter { $0.verdict == .unsure }.count
        let extraCallsSum = rows.reduce(0) { $0 + $1.extraCalls }

        lines.append("")
        lines.append("## Итоги")
        lines.append("")
        lines.append("- Всего примеров: \(total)")
        lines.append("- Доля FAIL: \(percent(failCount, total)) (\(failCount))")
        lines.append("- Доля UNSURE: \(percent(unsureCount, total)) (\(unsureCount))")
        lines.append("- Отклонено (FAIL): \(failCount)")
        lines.append("- Доп. вызовов суммарно: \(extraCallsSum)")
        lines.append(String(format: "- Средняя наценка latency: ×%.2f", averageLatencyOverhead(rows)))
        return lines.joined(separator: "\n")
    }

    static func renderSummary(baseline: [BatchRow], tuned: [BatchRow]) -> String {
        var lines = ["# Сравнение baseline и тюна", "", "| метрика | baseline | тюн |", "|---|---|---|"]
        lines.append(metricRow("точность по проверкам", checkAccuracy(baseline), checkAccuracy(tuned)))
        lines.append(metricRow("доля OK", verdictShare(baseline, .ok), verdictShare(tuned, .ok)))
        lines.append(metricRow("доля UNSURE", verdictShare(baseline, .unsure), verdictShare(tuned, .unsure)))
        lines.append(metricRow("доля FAIL", verdictShare(baseline, .fail), verdictShare(tuned, .fail)))
        lines.append("| средняя latency, осн. | " + latencyDescription(baseline) + " | " + latencyDescription(tuned) + " |")
        return lines.joined(separator: "\n")
    }

    private static func evenStep<T>(_ pool: [T], count: Int) -> [T] {
        guard !pool.isEmpty else { return [] }
        let n = min(count, pool.count)
        return (0..<n).map { pool[$0 * pool.count / n] }
    }

    private static func percent(_ part: Int, _ total: Int) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.0f%%", 100.0 * Double(part) / Double(total))
    }

    private static func averageLatencyOverhead(_ rows: [BatchRow]) -> Double {
        let withLatency = rows.filter { $0.primaryLatency > 0 }
        guard !withLatency.isEmpty else { return 1.0 }
        let sum = withLatency.reduce(0.0) { $0 + $1.totalLatency / $1.primaryLatency }
        return sum / Double(withLatency.count)
    }

    private static func checkAccuracy(_ rows: [BatchRow]) -> String {
        let total = rows.reduce(0) { $0 + $1.checksTotal }
        guard total > 0 else { return "—" }
        let passed = rows.reduce(0) { $0 + $1.checksPassed }
        return percent(passed, total)
    }

    private static func verdictShare(_ rows: [BatchRow], _ verdict: ConfidenceVerdict) -> String {
        percent(rows.filter { $0.verdict == verdict }.count, rows.count)
    }

    private static func latencyDescription(_ rows: [BatchRow]) -> String {
        guard !rows.isEmpty else { return "—" }
        let avg = rows.reduce(0.0) { $0 + $1.primaryLatency } / Double(rows.count)
        return String(format: "%.2fс", avg)
    }

    private static func metricRow(_ name: String, _ baseline: String, _ tuned: String) -> String {
        "| \(name) | \(baseline) | \(tuned) |"
    }
}
