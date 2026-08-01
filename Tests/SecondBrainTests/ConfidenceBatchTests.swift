// ConfidenceBatchTests.swift — задача 85: детерминированная подборка 20 (10/5/5) и
// рендер Markdown-отчётов батч-прогона.

import XCTest
@testable import SecondBrain

final class ConfidenceBatchTests: XCTestCase {
    private func nonEmptyRef(_ n: Int = 1) -> String {
        let items = (0..<n).map { "{\"assignee\": null, \"task\": \"дело \($0)\", \"due\": null}" }
        return "{\"action_items\": [\(items.joined(separator: ", "))]}"
    }
    private let emptyRef = "{\"action_items\": []}"

    private func examples(nonEmptyCount: Int, emptyCount: Int, extraLong: Int = 0)
        -> [(index: Int, transcript: String, reference: String)] {
        var result: [(index: Int, transcript: String, reference: String)] = []
        for i in 0..<nonEmptyCount {
            result.append((index: i, transcript: "транскрипт \(i)", reference: nonEmptyRef()))
        }
        for i in 0..<emptyCount {
            result.append((index: nonEmptyCount + i, transcript: "пустой транскрипт \(i)", reference: emptyRef))
        }
        for i in 0..<extraLong {
            let index = nonEmptyCount + emptyCount + i
            result.append((index: index, transcript: String(repeating: "длинный текст ", count: 50 + i), reference: emptyRef))
        }
        return result
    }

    // MARK: - plan

    func testPlanComposition10_5_5() {
        let input = examples(nonEmptyCount: 30, emptyCount: 20, extraLong: 20)
        let items = ConfidenceBatch.plan(examples: input)
        XCTAssertEqual(items.filter { $0.kind == "непустой" }.count, 10)
        XCTAssertEqual(items.filter { $0.kind == "пустой" }.count, 5)
        XCTAssertEqual(items.filter { $0.kind == "шумный" }.count, 5)
        XCTAssertEqual(items.count, 20)
    }

    func testPlanIsDeterministicAcrossCalls() {
        let input = examples(nonEmptyCount: 30, emptyCount: 20, extraLong: 20)
        let first = ConfidenceBatch.plan(examples: input).map(\.index)
        let second = ConfidenceBatch.plan(examples: input).map(\.index)
        XCTAssertEqual(first, second)
    }

    func testPlanNoisyPicksLongestRemainingTranscripts() {
        let input = examples(nonEmptyCount: 30, emptyCount: 20, extraLong: 20)
        let items = ConfidenceBatch.plan(examples: input)
        let noisy = items.filter { $0.kind == "шумный" }
        let lengths = noisy.map(\.transcript.count)
        XCTAssertEqual(lengths, lengths.sorted(by: >))
        // «шумные» пришли из хвоста extraLong (самые длинные тексты).
        XCTAssertTrue(noisy.allSatisfy { $0.index >= 50 })
    }

    func testPlanSmallInputTakesWhatIsAvailableWithoutCrashing() {
        let input = examples(nonEmptyCount: 2, emptyCount: 1)
        let items = ConfidenceBatch.plan(examples: input)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.index)), Set([0, 1, 2]))
    }

    func testPlanEmptyInputReturnsEmpty() {
        XCTAssertEqual(ConfidenceBatch.plan(examples: []), [])
    }

    func testPlanAllExamplesEmptyReferenceOnlyEmptyAndNoisyBuckets() {
        let input = examples(nonEmptyCount: 0, emptyCount: 30)
        let items = ConfidenceBatch.plan(examples: input)
        XCTAssertEqual(items.filter { $0.kind == "непустой" }.count, 0)
        XCTAssertEqual(items.filter { $0.kind == "пустой" }.count, 5)
        // «шумные» добираются из остатка пустого пула — непустых и «прочих» нет вовсе.
        XCTAssertEqual(items.filter { $0.kind == "шумный" }.count, 5)
        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(Set(items.map(\.index)).count, items.count, "без дублей индексов")
    }

    func testPlanAllExamplesNonEmptyReferenceOnlyNonEmptyAndNoisyBuckets() {
        let input = examples(nonEmptyCount: 30, emptyCount: 0)
        let items = ConfidenceBatch.plan(examples: input)
        XCTAssertEqual(items.filter { $0.kind == "непустой" }.count, 10)
        XCTAssertEqual(items.filter { $0.kind == "пустой" }.count, 0)
        XCTAssertEqual(items.filter { $0.kind == "шумный" }.count, 5)
        XCTAssertEqual(items.count, 15)
    }

    /// Ровно 20 примеров на входе (10 непустых + 5 пустых + 5 «шумных» кандидатов) —
    /// план использует все, без дублей и без пропусков.
    func testPlanExactly20InputExamplesUsesAllOfThem() {
        let input = examples(nonEmptyCount: 10, emptyCount: 5, extraLong: 5)
        XCTAssertEqual(input.count, 20)
        let items = ConfidenceBatch.plan(examples: input)
        XCTAssertEqual(items.count, 20)
        XCTAssertEqual(Set(items.map(\.index)), Set(input.map(\.index)))
    }

    // MARK: - renderReport

    private func row(index: Int, verdict: ConfidenceVerdict) -> BatchRow {
        BatchRow(index: index, kind: "непустой", verdict: verdict, checksPassed: 6, checksTotal: 9,
                 redundancy: .agree, scoringStatus: "OK", scoringConfidence: 82,
                 primaryLatency: 1.5, totalLatency: 3.0, promptTokens: 100, completionTokens: 40, extraCalls: 2)
    }

    func testRenderReportContainsTableAndTotals() {
        let rows = [row(index: 1, verdict: .ok), row(index: 2, verdict: .fail), row(index: 3, verdict: .unsure)]
        let text = ConfidenceBatch.renderReport(title: "Baseline", rows: rows)
        XCTAssertTrue(text.contains("# Baseline"))
        XCTAssertTrue(text.contains("| № | тип | вердикт |"))
        XCTAssertTrue(text.contains("ok"))
        XCTAssertTrue(text.contains("fail"))
        XCTAssertTrue(text.contains("unsure"))
        XCTAssertTrue(text.contains("Всего примеров: 3"))
        XCTAssertTrue(text.contains("Отклонено (FAIL): 1"))
        XCTAssertTrue(text.contains("Доп. вызовов суммарно: 6"))
        XCTAssertTrue(text.contains("Средняя наценка latency"))
    }

    func testRenderReportEmptyRowsDoesNotCrash() {
        let text = ConfidenceBatch.renderReport(title: "Пусто", rows: [])
        XCTAssertTrue(text.contains("Всего примеров: 0"))
    }

    // MARK: - renderSummary

    func testRenderSummaryContainsComparisonTable() {
        let baseline = [row(index: 1, verdict: .ok), row(index: 2, verdict: .unsure)]
        let tuned = [row(index: 1, verdict: .ok), row(index: 2, verdict: .ok)]
        let text = ConfidenceBatch.renderSummary(baseline: baseline, tuned: tuned)
        XCTAssertTrue(text.contains("# Сравнение baseline и тюна"))
        XCTAssertTrue(text.contains("| метрика | baseline | тюн |"))
        XCTAssertTrue(text.contains("точность по проверкам"))
        XCTAssertTrue(text.contains("доля OK"))
    }
}
