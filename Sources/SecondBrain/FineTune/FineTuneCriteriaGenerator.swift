// FineTuneCriteriaGenerator.swift — одноразовый вызов LLM для criteria.md (задача 83).
//
// Фоллбэк по цепочке провайдеров — образец MeetingPipeline.summarizeStep: пусто
// кандидатов → ошибка с инструкцией, отмена не глотается, падение провайдера пробует
// следующего, все упали → последняя ошибка.

import Foundation

@MainActor
final class FineTuneCriteriaGenerator {
    private let providers: () -> [ResolvedChatProvider]

    init(providers: @escaping () -> [ResolvedChatProvider]) {
        self.providers = providers
    }

    func generate(datasetTitle: String, system: String?, examples: [FineTuneExample]) async throws -> String {
        let candidates = providers()
        guard !candidates.isEmpty else { throw FineTuneError.noChatProvider }

        let sampled = FineTuneCriteriaPrompts.sampleExamples(examples)
        let messages = FineTuneCriteriaPrompts.buildMessages(
            datasetTitle: datasetTitle, system: system, examples: sampled)

        var lastError: Error?
        for resolved in candidates {
            do {
                let result = try await resolved.provider.send(messages, settings: ChatSettings(model: resolved.model))
                let text = FineTuneCriteriaPrompts.postprocess(result.text)
                guard !text.isEmpty else { throw FineTuneError.emptyCriteriaResponse }
                return text
            } catch is CancellationError {
                throw CancellationError() // отмену не глотаем в фоллбэк
            } catch {
                lastError = error // провайдер не смог — следующий кандидат
            }
        }
        throw lastError ?? FineTuneError.noChatProvider
    }
}
