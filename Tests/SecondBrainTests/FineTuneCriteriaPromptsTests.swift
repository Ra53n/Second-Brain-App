// FineTuneCriteriaPromptsTests.swift — задача 83: чистое ядро генерации criteria.md.
//
// sampleExamples — равномерный детерминированный шаг и обрезка по бюджету символов;
// buildMessages — роли и структура сообщений; postprocess — срез markdown-обёртки.

import XCTest
@testable import SecondBrain

final class FineTuneCriteriaPromptsTests: XCTestCase {
    private func example(_ id: Int, user: String = "задание", assistant: String = "ответ") -> FineTuneExample {
        FineTuneExample(id: id, system: "S", user: user, assistant: assistant, meta: nil)
    }

    // MARK: - sampleExamples

    func testSampleExamplesEmptyInputReturnsEmpty() {
        XCTAssertEqual(FineTuneCriteriaPrompts.sampleExamples([]), [])
    }

    func testSampleExamplesSingleInputReturnsIt() {
        let examples = [example(0)]
        XCTAssertEqual(FineTuneCriteriaPrompts.sampleExamples(examples).map(\.id), [0])
    }

    func testSampleExamplesEvenStepAcrossTwentyWithLimitEight() {
        let examples = (0..<20).map { example($0) }
        let sampled = FineTuneCriteriaPrompts.sampleExamples(examples, limit: 8)
        XCTAssertEqual(sampled.count, 8)
        XCTAssertEqual(sampled.map(\.id), [0, 2, 5, 7, 10, 12, 15, 17])
    }

    func testSampleExamplesDeterministicAcrossRepeatedCalls() {
        let examples = (0..<20).map { example($0) }
        let first = FineTuneCriteriaPrompts.sampleExamples(examples, limit: 8).map(\.id)
        let second = FineTuneCriteriaPrompts.sampleExamples(examples, limit: 8).map(\.id)
        XCTAssertEqual(first, second)
    }

    func testSampleExamplesFewerThanLimitReturnsAll() {
        let examples = (0..<3).map { example($0) }
        XCTAssertEqual(FineTuneCriteriaPrompts.sampleExamples(examples, limit: 8).count, 3)
    }

    func testSampleExamplesTrimsFromEndToFitBudgetKeepingAtLeastOne() {
        let big = String(repeating: "x", count: 10_000)
        let examples = (0..<5).map { example($0, user: big, assistant: big) }
        let sampled = FineTuneCriteriaPrompts.sampleExamples(examples, limit: 5, charBudget: 25_000)
        XCTAssertGreaterThanOrEqual(sampled.count, 1)
        XCTAssertLessThan(sampled.count, 5, "бюджет 25к при 5×20к обязан урезать выборку")
        let total = sampled.reduce(0) { $0 + $1.user.count + $1.assistant.count }
        XCTAssertTrue(total <= 25_000 || sampled.count == 1, "либо влезли в бюджет, либо остался минимум один")
    }

    func testSampleExamplesNeverReturnsEmptyForNonemptyInputEvenOverBudget() {
        let huge = String(repeating: "x", count: 100_000)
        let examples = [example(0, user: huge, assistant: huge)]
        XCTAssertEqual(FineTuneCriteriaPrompts.sampleExamples(examples, charBudget: 1).count, 1)
    }

    // MARK: - buildMessages

    func testBuildMessagesFirstIsSystemInstruction() {
        let messages = FineTuneCriteriaPrompts.buildMessages(datasetTitle: "d", system: nil, examples: [])
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertFalse(messages.first?.content.isEmpty ?? true)
    }

    func testBuildMessagesUserIncludesDatasetSystemPromptAndExampleBlocks() {
        let examples = [example(0, user: "ЗАДАНИЕ1", assistant: "ЭТАЛОН1"),
                        example(1, user: "ЗАДАНИЕ2", assistant: "ЭТАЛОН2")]
        let messages = FineTuneCriteriaPrompts.buildMessages(
            datasetTitle: "мой датасет", system: "системный промпт X", examples: examples)
        XCTAssertEqual(messages.count, 2)
        let userText = messages[1].content
        XCTAssertEqual(messages[1].role, .user)
        XCTAssertTrue(userText.contains("системный промпт X"))
        XCTAssertTrue(userText.contains("[ПРИМЕР 1]"))
        XCTAssertTrue(userText.contains("ЗАДАНИЕ1"))
        XCTAssertTrue(userText.contains("ЭТАЛОН1"))
        XCTAssertTrue(userText.contains("[ПРИМЕР 2]"))
        XCTAssertTrue(userText.contains("ЗАДАНИЕ2"))
    }

    func testBuildMessagesWithoutDatasetSystemPromptOmitsIt() {
        let messages = FineTuneCriteriaPrompts.buildMessages(
            datasetTitle: "d", system: nil, examples: [example(0)])
        XCTAssertFalse(messages[1].content.contains("Системный промпт"))
    }

    // MARK: - postprocess

    func testPostprocessStripsMarkdownFence() {
        let wrapped = "```markdown\n# Критерии\n\nтекст\n```"
        XCTAssertEqual(FineTuneCriteriaPrompts.postprocess(wrapped), "# Критерии\n\nтекст")
    }

    func testPostprocessStripsBareFence() {
        let wrapped = "```\n# Критерии\n```"
        XCTAssertEqual(FineTuneCriteriaPrompts.postprocess(wrapped), "# Критерии")
    }

    func testPostprocessLeavesUnwrappedTextUntouched() {
        let text = "# Критерии\n\nобычный текст без обёртки"
        XCTAssertEqual(FineTuneCriteriaPrompts.postprocess(text), text)
    }

    func testPostprocessTrimsSurroundingWhitespace() {
        XCTAssertEqual(FineTuneCriteriaPrompts.postprocess("  \n# X\n  \n"), "# X")
    }

    func testPostprocessDoesNotTouchInternalCodeFences() {
        let text = "# Критерии\n\n```json\n{\"a\": 1}\n```\n\nостальное"
        XCTAssertEqual(FineTuneCriteriaPrompts.postprocess(text), text)
    }
}
