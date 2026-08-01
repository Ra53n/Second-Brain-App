// RedundancyComparerTests.swift — задача 85: согласие N повторных прогонов.

import XCTest
@testable import SecondBrain

final class RedundancyComparerTests: XCTestCase {
    private func item(_ assignee: String?, _ task: String, _ due: String?) -> ActionItem {
        ActionItem(assignee: assignee, task: task, due: due)
    }

    func testThreeIdenticalAnswersAgree() {
        let answer = [item("Аня", "сделать отчёт", "пятница")]
        XCTAssertEqual(RedundancyComparer.compare([answer, answer, answer]), .agree)
    }

    func testAllEmptyListsAgree() {
        let empty: [ActionItem] = []
        XCTAssertEqual(RedundancyComparer.compare([empty, empty, empty]), .agree)
    }

    func testTwoOfThreeMatchIsPartial() {
        let a = [item("Аня", "сделать отчёт", "пятница")]
        let b = [item("Аня", "сделать отчет", "пятница")]     // ratio >= 0.8, e/ё
        let c = [item("Петя", "купить билеты", nil)]
        XCTAssertEqual(RedundancyComparer.compare([a, b, c]), .partial)
    }

    func testAllThreeDifferentIsDisagree() {
        let a = [item("Аня", "сделать отчёт", "пятница")]
        let b = [item("Петя", "купить билеты", nil)]
        let c = [item("Оля", "написать письмо", "среда")]
        XCTAssertEqual(RedundancyComparer.compare([a, b, c]), .disagree)
    }

    func testSingleAnswerAgrees() {
        XCTAssertEqual(RedundancyComparer.compare([[item("Аня", "сделать", nil)]]), .agree)
    }

    func testTaskWordOrderPermutationAboveThresholdAgrees() {
        let a = [item("Аня", "собрать команду и обсудить план", nil)]
        let b = [item("Аня", "собрать команду обсудить план", nil)]  // ratio 0.9667
        XCTAssertEqual(RedundancyComparer.compare([a, b]), .agree)
    }

    func testDifferentAssigneeBreaksMatchEvenWithSameTask() {
        let a = [item("Аня", "сделать отчёт", nil)]
        let b = [item("Петя", "сделать отчёт", nil)]
        XCTAssertEqual(RedundancyComparer.compare([a, b]), .disagree)
    }

    func testDifferentCountsNeverMatch() {
        let a = [item("Аня", "сделать отчёт", nil)]
        let b = [item("Аня", "сделать отчёт", nil), item("Петя", "купить билеты", nil)]
        XCTAssertEqual(RedundancyComparer.compare([a, b]), .disagree)
    }

    func testOrderIndependentMatching() {
        let a = [item("Аня", "сделать отчёт", nil), item("Петя", "купить билеты", nil)]
        let b = [item("Петя", "купить билеты", nil), item("Аня", "сделать отчёт", nil)]
        XCTAssertEqual(RedundancyComparer.compare([a, b]), .agree)
    }
}
