// FineTuneImportCoreTests.swift — задача 83: разбор импортируемого JSONL и
// детерминированный сплит (P1, без I/O).
//
// parse(): валидные/битые строки, порядок ролей, пустой content, расхождение
// system, пустые строки в середине, кириллица; split(): детерминизм, границы
// count 2/10/5, покрытие индексов; sanitizeName; syntheticMetaLine; splitSummary.

import XCTest
@testable import SecondBrain

final class FineTuneImportCoreParseTests: XCTestCase {
    private func line(system: String = "S", user: String, assistant: String) -> String {
        let payload = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
                ["role": "assistant", "content": assistant]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    func testValidFileParsesAllLines() {
        let text = [line(user: "U1", assistant: "A1"), line(user: "U2", assistant: "A2")].joined(separator: "\n")
        let result = FineTuneImportCore.parse(text: text)
        XCTAssertEqual(result.examples.count, 2)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.examples[0].rawLine, line(user: "U1", assistant: "A1"))
    }

    func testBrokenJSONReportsNotJSON() {
        let result = FineTuneImportCore.parse(text: "{ не json")
        XCTAssertEqual(result.examples.count, 0)
        XCTAssertEqual(result.issues, [.init(line: 1, reason: "не JSON")])
    }

    func testTwoMessagesReportsWrongCount() {
        let payload = #"{"messages":[{"role":"user","content":"U"},{"role":"assistant","content":"A"}]}"#
        let result = FineTuneImportCore.parse(text: payload)
        XCTAssertEqual(result.issues, [.init(line: 1, reason: "ожидаются ровно три сообщения system/user/assistant")])
    }

    func testWrongRoleOrderReportsWrongCount() {
        let payload = #"{"messages":[{"role":"system","content":"S"},{"role":"assistant","content":"A"},{"role":"user","content":"U"}]}"#
        let result = FineTuneImportCore.parse(text: payload)
        XCTAssertEqual(result.issues, [.init(line: 1, reason: "ожидаются ровно три сообщения system/user/assistant")])
    }

    func testEmptyContentReportsEmptyContent() {
        let text = line(user: "U", assistant: "A") + "\n" + line(user: "   ", assistant: "A2")
        let result = FineTuneImportCore.parse(text: text)
        XCTAssertEqual(result.examples.count, 1)
        XCTAssertEqual(result.issues, [.init(line: 2, reason: "пустой content")])
    }

    func testDivergingSystemRejectedAfterFirstLine() {
        let text = [line(system: "A", user: "U1", assistant: "A1"),
                    line(system: "B", user: "U2", assistant: "A2")].joined(separator: "\n")
        let result = FineTuneImportCore.parse(text: text)
        XCTAssertEqual(result.examples.count, 1)
        XCTAssertEqual(result.examples[0].system, "A")
        XCTAssertEqual(result.issues, [.init(line: 2, reason: "system отличается от первого примера")])
    }

    func testBlankLinesInTheMiddleAreSkippedSilently() {
        let text = [line(user: "U1", assistant: "A1"), "", "   ", line(user: "U2", assistant: "A2")]
            .joined(separator: "\n")
        let result = FineTuneImportCore.parse(text: text)
        XCTAssertEqual(result.examples.count, 2)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testCyrillicContentPreservedExactly() {
        let text = line(system: "Ты — ассистент.", user: "Заметка про кофе ☕", assistant: "Готово.")
        let result = FineTuneImportCore.parse(text: text)
        XCTAssertEqual(result.examples.first?.system, "Ты — ассистент.")
        XCTAssertEqual(result.examples.first?.user, "Заметка про кофе ☕")
    }

    func testLineNumbersAreOneBasedByFileLine() {
        let text = "\n" + line(user: "U1", assistant: "A1")
        let result = FineTuneImportCore.parse(text: text)
        XCTAssertEqual(result.examples.count, 1)
        XCTAssertTrue(result.issues.isEmpty)
    }
}

final class FineTuneImportCoreSplitTests: XCTestCase {
    func testSameSeedIsDeterministic() {
        let first = FineTuneImportCore.split(count: 37, seed: 42)
        let second = FineTuneImportCore.split(count: 37, seed: 42)
        XCTAssertEqual(first.train, second.train)
        XCTAssertEqual(first.valid, second.valid)
    }

    func testDifferentSeedsCanDiffer() {
        let a = FineTuneImportCore.split(count: 50, seed: 1)
        let b = FineTuneImportCore.split(count: 50, seed: 2)
        XCTAssertNotEqual(a.valid, b.valid, "разные seed почти наверняка дают разный порядок")
    }

    func testCountTwoYieldsOneTrainOneValid() {
        let result = FineTuneImportCore.split(count: 2, seed: 7)
        XCTAssertEqual(result.train.count, 1)
        XCTAssertEqual(result.valid.count, 1)
    }

    func testCountTenYieldsEightTrainTwoValid() {
        let result = FineTuneImportCore.split(count: 10, seed: 7)
        XCTAssertEqual(result.train.count, 8)
        XCTAssertEqual(result.valid.count, 2)
    }

    func testCountFiveWithDefaultFractionHasAtLeastOneValid() {
        let result = FineTuneImportCore.split(count: 5, seed: 7)
        XCTAssertGreaterThanOrEqual(result.valid.count, 1)
        XCTAssertGreaterThanOrEqual(result.train.count, 1)
    }

    func testIndicesAreUniqueAndCoverFullRange() {
        for count in [2, 5, 10, 37, 1000] {
            let result = FineTuneImportCore.split(count: count, seed: 99)
            let all = Set(result.train + result.valid)
            XCTAssertEqual(all.count, count, "count \(count) — дубликаты или потерянные индексы")
            XCTAssertEqual(all, Set(0..<count))
        }
    }

    func testEachPartSortedAscending() {
        let result = FineTuneImportCore.split(count: 37, seed: 3)
        XCTAssertEqual(result.train, result.train.sorted())
        XCTAssertEqual(result.valid, result.valid.sorted())
    }

    func testCountOneHasNoValid() {
        let result = FineTuneImportCore.split(count: 1, seed: 5)
        XCTAssertEqual(result.train, [0])
        XCTAssertEqual(result.valid, [])
    }

    func testCountZeroYieldsEmpty() {
        let result = FineTuneImportCore.split(count: 0, seed: 5)
        XCTAssertEqual(result.train, [])
        XCTAssertEqual(result.valid, [])
    }
}

final class FineTuneImportCoreSanitizeNameTests: XCTestCase {
    func testCyrillicAndSpacesAreStripped() {
        XCTAssertEqual(FineTuneImportCore.sanitizeName("Мой датасет 2026"), "2026")
    }

    func testDotsAndSlashesAreStripped() {
        XCTAssertEqual(FineTuneImportCore.sanitizeName("my.dataset/v1"), "mydatasetv1")
    }

    func testAllowedCharactersPassThrough() {
        XCTAssertEqual(FineTuneImportCore.sanitizeName("my-data_set-01"), "my-data_set-01")
    }

    func testEmptyAfterCleaningIsNil() {
        XCTAssertNil(FineTuneImportCore.sanitizeName("датасет"))
    }

    func testReservedNameIsNilCaseInsensitively() {
        XCTAssertNil(FineTuneImportCore.sanitizeName("data"))
        XCTAssertNil(FineTuneImportCore.sanitizeName("Data"))
        XCTAssertNil(FineTuneImportCore.sanitizeName("TUNED"))
        XCTAssertNil(FineTuneImportCore.sanitizeName("__pycache__"))
    }

    func testEmptyStringIsNil() {
        XCTAssertNil(FineTuneImportCore.sanitizeName(""))
    }
}

final class FineTuneImportCoreSyntheticMetaTests: XCTestCase {
    func testFormatMatchesFourDigitZeroPaddedID() {
        XCTAssertEqual(FineTuneImportCore.syntheticMetaLine(index: 1),
                       #"{"id":"ex-0001","source_post":"ex-0001","task_type":"imported"}"#)
        XCTAssertEqual(FineTuneImportCore.syntheticMetaLine(index: 42),
                       #"{"id":"ex-0042","source_post":"ex-0042","task_type":"imported"}"#)
    }

    func testParsableByExistingMetaParser() {
        let meta = FineTuneJSONL.parseMeta(line: FineTuneImportCore.syntheticMetaLine(index: 3))
        XCTAssertEqual(meta?.id, "ex-0003")
        XCTAssertEqual(meta?.sourcePost, "ex-0003")
        XCTAssertEqual(meta?.taskType, "imported")
    }
}

final class FineTuneImportCoreSplitSummaryTests: XCTestCase {
    func testDecodesAsFineTuneSplitInfo() throws {
        let data = FineTuneImportCore.splitSummary(seed: 12345, trainCount: 8, validCount: 2, evalFraction: 0.2)
        let info = try JSONDecoder().decode(FineTuneSplitInfo.self, from: data)
        XCTAssertEqual(info.seed, 12345)
        XCTAssertEqual(info.evalFractionTarget, 0.2)
        XCTAssertEqual(info.evalPosts, [])
        XCTAssertEqual(info.counts.train, 8)
        XCTAssertEqual(info.counts.valid, 2)
    }
}
