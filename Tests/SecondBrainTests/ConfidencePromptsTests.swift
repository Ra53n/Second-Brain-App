// ConfidencePromptsTests.swift — задача 85: толерантные парсеры scoring/self-check на
// корректном и мусорном вводе (модель натаскана на другой контракт — может не ответить
// по формату этих отдельных промптов).

import XCTest
@testable import SecondBrain

final class ConfidencePromptsTests: XCTestCase {

    // MARK: - scoringPrompt / selfCheckPrompt

    func testScoringPromptContainsTranscriptAndAnswer() {
        let prompt = ConfidencePrompts.scoringPrompt(transcript: "ТРАНСКРИПТ_X", answer: "ОТВЕТ_Y")
        XCTAssertTrue(prompt.contains("ТРАНСКРИПТ_X"))
        XCTAssertTrue(prompt.contains("ОТВЕТ_Y"))
    }

    func testSelfCheckPromptContainsTranscriptAndAnswer() {
        let prompt = ConfidencePrompts.selfCheckPrompt(transcript: "ТРАНСКРИПТ_X", answer: "ОТВЕТ_Y")
        XCTAssertTrue(prompt.contains("ТРАНСКРИПТ_X"))
        XCTAssertTrue(prompt.contains("ОТВЕТ_Y"))
    }

    // MARK: - parseScoring

    func testParseScoringCleanJSON() {
        let signal = ConfidencePrompts.parseScoring(#"{"status": "OK", "confidence": 80}"#)
        XCTAssertEqual(signal?.status, "OK")
        XCTAssertEqual(signal?.confidence, 80)
    }

    func testParseScoringJSONEmbeddedInProse() {
        let raw = "Конечно, вот моя оценка:\n{\"status\": \"UNSURE\", \"confidence\": 55}\nСпасибо за внимание."
        let signal = ConfidencePrompts.parseScoring(raw)
        XCTAssertEqual(signal?.status, "UNSURE")
        XCTAssertEqual(signal?.confidence, 55)
    }

    func testParseScoringConfidenceAsString() {
        let signal = ConfidencePrompts.parseScoring(#"{"status": "OK", "confidence": "80"}"#)
        XCTAssertEqual(signal?.confidence, 80)
    }

    func testParseScoringEmptyStringIsNil() {
        XCTAssertNil(ConfidencePrompts.parseScoring(""))
    }

    func testParseScoringTextWithoutJSONFallsBackToNumber() {
        let signal = ConfidencePrompts.parseScoring("Я уверен процентов на 72, наверное")
        XCTAssertEqual(signal?.confidence, 72)
        XCTAssertNil(signal?.status)
    }

    func testParseScoringCompleteGarbageIsNil() {
        XCTAssertNil(ConfidencePrompts.parseScoring("абсолютно никакой полезной информации тут"))
    }

    func testParseScoringMalformedJSONFallsBackToNumber() {
        let signal = ConfidencePrompts.parseScoring("{status: OK, confidence: 65 (не совсем JSON)")
        XCTAssertEqual(signal?.confidence, 65)
    }

    // MARK: - parseSelfCheck

    func testParseSelfCheckCleanJSON() {
        let raw = #"{"items": [{"supported": true, "reason": "названо явно"}, {"supported": false, "reason": "не упомянуто"}], "missed": false}"#
        let signal = ConfidencePrompts.parseSelfCheck(raw, expectedCount: 2)
        XCTAssertEqual(signal?.supported, [true, false])
        XCTAssertEqual(signal?.reasons, ["названо явно", "не упомянуто"])
        XCTAssertEqual(signal?.missed, false)
    }

    func testParseSelfCheckMissedTrue() {
        let raw = #"{"items": [], "missed": true}"#
        let signal = ConfidencePrompts.parseSelfCheck(raw, expectedCount: 1)
        XCTAssertEqual(signal?.missed, true)
        XCTAssertEqual(signal?.supported, [])
    }

    func testParseSelfCheckEmptyStringIsNil() {
        XCTAssertNil(ConfidencePrompts.parseSelfCheck("", expectedCount: 1))
    }

    func testParseSelfCheckTextWithoutJSONIsNil() {
        XCTAssertNil(ConfidencePrompts.parseSelfCheck("не могу проверить, простите", expectedCount: 1))
    }

    func testParseSelfCheckMismatchedCountIsAcceptedAsIs() {
        let raw = #"{"items": [{"supported": true, "reason": "x"}], "missed": false}"#
        let signal = ConfidencePrompts.parseSelfCheck(raw, expectedCount: 3)
        XCTAssertEqual(signal?.supported.count, 1)
    }

    func testParseSelfCheckJSONEmbeddedInProse() {
        let raw = "Проверил:\n{\"items\": [{\"supported\": true, \"reason\": \"да\"}], \"missed\": false}\nГотово."
        let signal = ConfidencePrompts.parseSelfCheck(raw, expectedCount: 1)
        XCTAssertEqual(signal?.supported, [true])
    }

    // MARK: - Задача 97: пустой ответ и кламп

    /// Кламп к expectedCount: модель выдумала пункты сверх реального ответа —
    /// лишние не считаются (живой источник ложных FAIL на валидных ответах).
    func testParseSelfCheckClampsInventedItemsToExpectedCount() {
        let raw = """
        {"items": [{"supported": true, "reason": "а"}, {"supported": false, "reason": "б"},
                   {"supported": false, "reason": "в"}], "missed": false}
        """
        let signal = ConfidencePrompts.parseSelfCheck(raw, expectedCount: 1)
        XCTAssertEqual(signal?.supported, [true], "считается только первый (реальный) пункт")
    }

    /// Модель вернула МЕНЬШЕ пунктов, чем в ответе: считаем пришедшие (оптимистично,
    /// прежнее поведение) — кламп режет только лишнее.
    func testParseSelfCheckFewerItemsThanExpectedCountsWhatCame() {
        let raw = "{\"items\": [{\"supported\": false, \"reason\": \"а\"}], \"missed\": false}"
        let signal = ConfidencePrompts.parseSelfCheck(raw, expectedCount: 3)
        XCTAssertEqual(signal?.supported, [false])
    }

    func testParseSelfCheckEmptyAnswerRequiresOnlyMissed() {
        let signal = ConfidencePrompts.parseSelfCheck("{\"missed\": true}", expectedCount: 0)
        XCTAssertEqual(signal?.supported, [])
        XCTAssertEqual(signal?.missed, true)
    }

    /// Модель проигнорировала инструкцию и прислала items на пустой ответ —
    /// выдуманные пункты отбрасываются целиком, missed берётся.
    func testParseSelfCheckEmptyAnswerIgnoresInventedItems() {
        let raw = "{\"items\": [{\"supported\": false, \"reason\": \"выдумано\"}], \"missed\": false}"
        let signal = ConfidencePrompts.parseSelfCheck(raw, expectedCount: 0)
        XCTAssertEqual(signal?.supported, [])
        XCTAssertEqual(signal?.missed, false)
    }

    func testParseSelfCheckEmptyAnswerWithoutMissedKeyIsNil() {
        XCTAssertNil(ConfidencePrompts.parseSelfCheck("{\"items\": []}", expectedCount: 0))
        XCTAssertNil(ConfidencePrompts.parseSelfCheck("мусор", expectedCount: 0))
    }

    func testSelfCheckEmptyPromptMentionsMissedOnlyContract() {
        let prompt = ConfidencePrompts.selfCheckEmptyPrompt(transcript: "Тимлид: обсудим завтра.")
        XCTAssertTrue(prompt.contains("Тимлид: обсудим завтра."))
        XCTAssertTrue(prompt.contains("{\"missed\": true|false}"))
        XCTAssertFalse(prompt.contains("\"items\""), "per-item подтверждений на пустом ответе нет")
    }
}
