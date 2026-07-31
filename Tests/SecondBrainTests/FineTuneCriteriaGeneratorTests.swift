// FineTuneCriteriaGeneratorTests.swift — задача 83: генерация criteria.md на MockChatProvider.
//
// Фоллбэк по цепочке кандидатов (образец MeetingPipeline.summarizeStep), ноль
// кандидатов и пустой ответ модели — понятные ошибки. Реальная сеть не задействована.

import XCTest
@testable import SecondBrain

@MainActor
final class FineTuneCriteriaGeneratorTests: XCTestCase {
    private func resolved(_ provider: MockChatProvider, id: String = "mock") -> ResolvedChatProvider {
        ResolvedChatProvider(provider: provider, model: "m", providerID: ProviderID(rawValue: id), displayName: id)
    }

    private func examples() -> [FineTuneExample] {
        [FineTuneExample(id: 0, system: "S", user: "задание", assistant: "ответ автора", meta: nil)]
    }

    func testGenerateReturnsFirstProviderResponse() async throws {
        let provider = MockChatProvider(responses: ["# Критерии\n\nдокумент"])
        let generator = FineTuneCriteriaGenerator(providers: { [self.resolved(provider)] })

        let text = try await generator.generate(datasetTitle: "d", system: nil, examples: examples())

        XCTAssertEqual(text, "# Критерии\n\nдокумент")
    }

    func testGenerateFallsBackToSecondProviderOnFailure() async throws {
        let failing = MockChatProvider()
        failing.errorToThrow = LLMError.emptyResponse
        let working = MockChatProvider(responses: ["документ второго провайдера"])
        let generator = FineTuneCriteriaGenerator(providers: {
            [self.resolved(failing, id: "broken"), self.resolved(working, id: "cloud")]
        })

        let text = try await generator.generate(datasetTitle: "d", system: nil, examples: examples())

        XCTAssertEqual(text, "документ второго провайдера")
    }

    func testGenerateWithNoCandidatesThrowsNoChatProvider() async throws {
        let generator = FineTuneCriteriaGenerator(providers: { [] })

        do {
            _ = try await generator.generate(datasetTitle: "d", system: nil, examples: examples())
            XCTFail("ожидалась ошибка noChatProvider")
        } catch {
            XCTAssertEqual(error as? FineTuneError, .noChatProvider)
        }
    }

    func testGenerateWithEmptyResponseThrowsEmptyCriteriaResponse() async throws {
        let provider = MockChatProvider(responses: ["   \n  "])
        let generator = FineTuneCriteriaGenerator(providers: { [self.resolved(provider)] })

        do {
            _ = try await generator.generate(datasetTitle: "d", system: nil, examples: examples())
            XCTFail("ожидалась ошибка emptyCriteriaResponse")
        } catch {
            XCTAssertEqual(error as? FineTuneError, .emptyCriteriaResponse)
        }
    }

    func testGenerateStripsMarkdownFenceFromResponse() async throws {
        let provider = MockChatProvider(responses: ["```markdown\n# Критерии\n```"])
        let generator = FineTuneCriteriaGenerator(providers: { [self.resolved(provider)] })

        let text = try await generator.generate(datasetTitle: "d", system: nil, examples: examples())

        XCTAssertEqual(text, "# Критерии")
    }
}
