// ConfidencePipelineTests.swift — оркестратор оценки уверенности (задача 85): жёсткий
// constraint-фейл завершает пайплайн без доп. вызовов, полный прогон считает вызовы,
// неспарсившийся повтор редьюсится в disagree, отмена не глотается.
//
// redundancyCount=3 в этом пайплайне означает 3 ПОЛНЫХ ответа (1 основной + 2 повтора,
// согласно «Допущения» задачи 85), поэтому полный прогон — 1 + 2 + scoring(1) +
// self-check(1) = 5 вызовов, не 6 — см. комментарий в ConfidencePipeline.swift.

import XCTest
@testable import SecondBrain

/// Провайдер по сценарию: текст/usage/ошибка на каждый вызов по порядку — покрывает то,
/// чего нет в `MockChatProvider` (usage всегда non-nil, ошибка одна и та же на всех вызовах).
private final class ScriptedChatProvider: ChatProvider {
    struct Step {
        var text: String = ""
        var usage: ChatUsage?
        var error: Error?
    }
    private var steps: [Step]
    private(set) var callCount = 0

    init(steps: [Step]) { self.steps = steps }

    func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
        defer { callCount += 1 }
        guard callCount < steps.count else { return ChatResult(text: "", usage: nil) }
        let step = steps[callCount]
        if let error = step.error { throw error }
        return ChatResult(text: step.text, usage: step.usage)
    }

    func stream(_ messages: [ChatMessageDTO], settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.emptyResponse) }
    }
}

private struct HarnessError: Error, Equatable { let message: String }

final class ConfidencePipelineTests: XCTestCase {

    func testHardConstraintFailureStopsAfterOneCall() async throws {
        let provider = MockChatProvider(responses: ["это точно не JSON"])
        let pipeline = ConfidencePipeline(provider: provider, settings: ChatSettings(model: "mlx"))
        let (raw, report) = try await pipeline.run(system: "s", transcript: "t", reference: nil)
        XCTAssertEqual(raw, "это точно не JSON")
        XCTAssertEqual(report.verdict, .fail)
        XCTAssertEqual(report.metrics.totalCalls, 1)
        XCTAssertEqual(report.metrics.extraCalls, 0)
        XCTAssertEqual(provider.receivedMessages.count, 1)
    }

    func testFullRunCountsAllCalls() async throws {
        let provider = MockChatProvider(responses: [
            "{\"action_items\":[]}",             // основной
            "{\"action_items\":[]}",             // redundancy #2
            "{\"action_items\":[]}",             // redundancy #3
            "{\"status\":\"OK\",\"confidence\":90}", // scoring
            "{\"items\":[],\"missed\":false}",   // self-check
        ])
        let pipeline = ConfidencePipeline(provider: provider, settings: ChatSettings(model: "mlx"), redundancyCount: 3)
        var progressSteps: [String] = []
        let (_, report) = try await pipeline.run(system: "s", transcript: "t", reference: nil) { progressSteps.append($0) }

        XCTAssertEqual(provider.receivedMessages.count, 5)
        XCTAssertEqual(report.metrics.totalCalls, 5)
        XCTAssertEqual(report.metrics.extraCalls, 4)
        XCTAssertEqual(report.redundancy, .agree)
        XCTAssertEqual(report.scoringStatus, "OK")
        XCTAssertEqual(report.scoringConfidence, 90)
        XCTAssertEqual(progressSteps, ["Вызов 2 из 3", "Вызов 3 из 3"])
    }

    func testUnparsedRedundancyRepeatBecomesDisagree() async throws {
        let provider = MockChatProvider(responses: [
            "{\"action_items\":[{\"assignee\":null,\"task\":\"сделать X\",\"due\":null}]}", // основной
            "мусор, не JSON",                                                                // redundancy #2 — не парсится
            "{\"action_items\":[{\"assignee\":null,\"task\":\"сделать X\",\"due\":null}]}", // redundancy #3
            "{\"status\":\"OK\",\"confidence\":80}",
            "{\"items\":[{\"supported\":true,\"reason\":\"ок\"}],\"missed\":false}",
        ])
        let pipeline = ConfidencePipeline(provider: provider, settings: ChatSettings(model: "mlx"), redundancyCount: 3)
        let (_, report) = try await pipeline.run(system: "s", transcript: "t", reference: nil)
        XCTAssertEqual(report.redundancy, .disagree, "неспарсившийся повтор — расхождение, не «пропускаем»")
    }

    /// Ollama-стиль ответов: usage отсутствует у каждого вызова — метрики токенов остаются
    /// нулевыми, пайплайн не падает и вердикт считается по остальным сигналам.
    func testUsageNilFromEveryCallDoesNotCrashAndTokensStayZero() async throws {
        let provider = ScriptedChatProvider(steps: [
            .init(text: "{\"action_items\":[]}", usage: nil),
            .init(text: "{\"action_items\":[]}", usage: nil),
            .init(text: "{\"action_items\":[]}", usage: nil),
            .init(text: "{\"status\":\"OK\",\"confidence\":90}", usage: nil),
            .init(text: "{\"items\":[],\"missed\":false}", usage: nil),
        ])
        let pipeline = ConfidencePipeline(provider: provider, settings: ChatSettings(model: "mlx"), redundancyCount: 3)
        let (_, report) = try await pipeline.run(system: "s", transcript: "t", reference: nil)
        XCTAssertEqual(report.metrics.promptTokens, 0)
        XCTAssertEqual(report.metrics.completionTokens, 0)
        XCTAssertEqual(report.metrics.totalCalls, 5)
        XCTAssertEqual(report.verdict, .ok)
    }

    /// Сеть падает на втором вызове (первый redundancy-повтор) — ошибка обязана дойти
    /// до вызывающего кода, не проглатываться в «деградированный» отчёт (P6).
    func testNetworkErrorMidRedundancyPropagatesNotSwallowed() async throws {
        let provider = ScriptedChatProvider(steps: [
            .init(text: "{\"action_items\":[]}", usage: nil),
            .init(error: HarnessError(message: "сеть упала")),
        ])
        let pipeline = ConfidencePipeline(provider: provider, settings: ChatSettings(model: "mlx"), redundancyCount: 3)
        do {
            _ = try await pipeline.run(system: "s", transcript: "t", reference: nil)
            XCTFail("ожидалась ошибка второго вызова")
        } catch let error as HarnessError {
            XCTAssertEqual(error.message, "сеть упала")
        }
        XCTAssertEqual(provider.callCount, 2, "прогон остановился на упавшем вызове, третий не сделан")
    }

    /// redundancyCount=1 — только основной ответ, повторов нет вовсе: сигнал redundancy
    /// недоступен (не .agree «по умолчанию»), причина попадает в reasons.
    func testRedundancyCountOneMakesNoExtraCallsAndRedundancyUnavailable() async throws {
        let provider = MockChatProvider(responses: [
            "{\"action_items\":[]}",
            "{\"status\":\"OK\",\"confidence\":90}",
            "{\"items\":[],\"missed\":false}",
        ])
        let pipeline = ConfidencePipeline(provider: provider, settings: ChatSettings(model: "mlx"), redundancyCount: 1)
        let (_, report) = try await pipeline.run(system: "s", transcript: "t", reference: nil)
        XCTAssertNil(report.redundancy)
        XCTAssertTrue(report.reasons.contains("Сверка повторов недоступна"))
        XCTAssertEqual(report.metrics.extraCalls, 2, "только scoring+self-check, без redundancy-повторов")
    }

    /// redundancyCount=2 — один повтор сверх основного; для N=2 «большинство» совпадает
    /// с полным согласием, промежуточного .partial для двух ответов не бывает.
    func testRedundancyCountTwoAgreesWhenBothAnswersMatch() async throws {
        let provider = MockChatProvider(responses: [
            "{\"action_items\":[{\"assignee\":null,\"task\":\"сделать X\",\"due\":null}]}",
            "{\"action_items\":[{\"assignee\":null,\"task\":\"сделать X\",\"due\":null}]}",
            "{\"status\":\"OK\",\"confidence\":90}",
            "{\"items\":[{\"supported\":true,\"reason\":\"ок\"}],\"missed\":false}",
        ])
        let pipeline = ConfidencePipeline(provider: provider, settings: ChatSettings(model: "mlx"), redundancyCount: 2)
        let (_, report) = try await pipeline.run(system: "s", transcript: "t", reference: nil)
        XCTAssertEqual(report.redundancy, .agree)
        XCTAssertEqual(report.metrics.totalCalls, 4)
    }

    func testCancellationPropagatesNotSwallowed() async throws {
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        provider.delay = 0.3
        let pipeline = ConfidencePipeline(provider: provider, settings: ChatSettings(model: "mlx"))
        let task = Task { try await pipeline.run(system: "s", transcript: "t", reference: nil) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("ожидалась отмена")
        } catch is CancellationError {
            // ок
        } catch {
            XCTFail("ожидалась CancellationError, получено \(error)")
        }
    }
}
