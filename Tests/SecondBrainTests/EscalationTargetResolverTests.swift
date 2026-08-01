// EscalationTargetResolverTests.swift — единственная точка контакта эскалации (задача 91)
// с `ProviderRegistry`: цель не выбрана, провайдер не зарегистрирован/недоступен, нет
// реализации ChatProvider, пустая модель → дефолт провайдера (в т.ч. когда дефолта нет),
// явная модель недоступна/доступна. Реестр — свежий на тест, провайдеры — `MockChatProvider`,
// сеть не участвует (`isLocal: true` — `isAvailable` не трогает Keychain/env).
// Задача 93: `.localTuned` ветвит ДО контакта с реестром — строитель `localTune` вызывается
// с `target.model`, реестр не участвует в резолюции вовсе (пустой реестр — резолв всё равно
// успешен через мок-строитель); `.registry` не зовёт `localTune` (счётчик вызовов).

import XCTest
@testable import SecondBrain

@MainActor
final class EscalationTargetResolverTests: XCTestCase {

    private func makeRegistry() -> ProviderRegistry {
        ProviderRegistry()
    }

    func testNilTargetIsUnavailable() {
        let registry = makeRegistry()
        let result = EscalationTargetResolver.resolve(target: nil, registry: registry)
        guard case let .unavailable(reason) = result else { return XCTFail("ожидали unavailable") }
        XCTAssertEqual(reason, "модель эскалации не выбрана")
    }

    func testUnknownProviderIDIsUnavailable() {
        let registry = makeRegistry()
        let target = EscalationTarget(providerID: "ghost", model: "")
        let result = EscalationTargetResolver.resolve(target: target, registry: registry)
        guard case let .unavailable(reason) = result else { return XCTFail("ожидали unavailable") }
        XCTAssertEqual(reason, "провайдер «ghost» недоступен")
    }

    func testRegisteredButUnavailableProviderIsUnavailable() {
        let registry = makeRegistry()
        registry.register(
            ProviderDescriptor(id: "local", displayName: "Локальный", capabilities: [.chat],
                                isLocal: true, defaultModel: "m"),
            chat: MockChatProvider(),
            isAvailable: { false })
        let target = EscalationTarget(providerID: "local", model: "")
        let result = EscalationTargetResolver.resolve(target: target, registry: registry)
        guard case let .unavailable(reason) = result else { return XCTFail("ожидали unavailable") }
        XCTAssertEqual(reason, "провайдер «local» недоступен")
    }

    /// Провайдер зарегистрирован и доступен, но без `ChatProvider`-реализации
    /// (например, только транскрипция) — вторая ступень эскалации невозможна.
    func testRegisteredWithoutChatImplementationIsUnavailable() {
        let registry = makeRegistry()
        registry.register(
            ProviderDescriptor(id: "onlyTranscription", displayName: "Только транскрипция",
                                capabilities: [.transcription], isLocal: true))
        let target = EscalationTarget(providerID: "onlyTranscription", model: "")
        let result = EscalationTargetResolver.resolve(target: target, registry: registry)
        guard case let .unavailable(reason) = result else { return XCTFail("ожидали unavailable") }
        XCTAssertEqual(reason, "провайдер «Только транскрипция» недоступен")
    }

    func testEmptyModelResolvesToProviderDefault() {
        let registry = makeRegistry()
        registry.register(
            ProviderDescriptor(id: "openai", displayName: "OpenAI", capabilities: [.chat],
                                isLocal: true, defaultModel: "gpt-5"),
            chat: MockChatProvider())
        let target = EscalationTarget(providerID: "openai", model: "")
        let result = EscalationTargetResolver.resolve(target: target, registry: registry)
        guard case let .resolved(resolved) = result else { return XCTFail("ожидали resolved") }
        XCTAssertEqual(resolved.model, "gpt-5")
        XCTAssertEqual(resolved.providerID, "openai")
        XCTAssertEqual(resolved.displayName, "OpenAI")
    }

    /// Пустая модель, а у провайдера нет пригодного дефолта (ни статичного, ни живого
    /// списка с хоть одной моделью) — не падаем, честно недоступно.
    func testEmptyModelWithoutAnyDefaultIsUnavailable() {
        let registry = makeRegistry()
        registry.register(
            ProviderDescriptor(id: "ollama", displayName: "Ollama", capabilities: [.chat], isLocal: true),
            chat: MockChatProvider(),
            availableModels: { _ in [] })
        let target = EscalationTarget(providerID: "ollama", model: "")
        let result = EscalationTargetResolver.resolve(target: target, registry: registry)
        guard case let .unavailable(reason) = result else { return XCTFail("ожидали unavailable") }
        XCTAssertEqual(reason, "у провайдера «Ollama» нет пригодной модели")
    }

    func testExplicitModelNotInLiveListIsUnavailable() {
        let registry = makeRegistry()
        registry.register(
            ProviderDescriptor(id: "ollama", displayName: "Ollama", capabilities: [.chat], isLocal: true),
            chat: MockChatProvider(),
            availableModels: { _ in ["qwen2.5:7b"] })
        let target = EscalationTarget(providerID: "ollama", model: "не-скачано:9b")
        let result = EscalationTargetResolver.resolve(target: target, registry: registry)
        guard case let .unavailable(reason) = result else { return XCTFail("ожидали unavailable") }
        XCTAssertEqual(reason, "модель «не-скачано:9b» недоступна у «Ollama»")
    }

    func testExplicitModelInLiveListResolves() {
        let registry = makeRegistry()
        let provider = MockChatProvider()
        registry.register(
            ProviderDescriptor(id: "ollama", displayName: "Ollama", capabilities: [.chat], isLocal: true),
            chat: provider,
            availableModels: { _ in ["qwen2.5:7b"] })
        let target = EscalationTarget(providerID: "ollama", model: "qwen2.5:7b")
        let result = EscalationTargetResolver.resolve(target: target, registry: registry)
        guard case let .resolved(resolved) = result else { return XCTFail("ожидали resolved") }
        XCTAssertEqual(resolved.model, "qwen2.5:7b")
    }

    /// Без резолвера живого списка (облако) — явная модель принимается без проверки
    /// (список моделей на стороне API не исчерпывающий).
    func testExplicitModelWithoutLiveListResolverIsAlwaysSelectable() {
        let registry = makeRegistry()
        let provider = MockChatProvider()
        registry.register(
            ProviderDescriptor(id: "openai", displayName: "OpenAI", capabilities: [.chat],
                                isLocal: true, defaultModel: "gpt-5"),
            chat: provider)
        let target = EscalationTarget(providerID: "openai", model: "gpt-5-mini")
        let result = EscalationTargetResolver.resolve(target: target, registry: registry)
        guard case let .resolved(resolved) = result else { return XCTFail("ожидали resolved") }
        XCTAssertEqual(resolved.model, "gpt-5-mini")
    }

    // MARK: - Задача 93: .localTuned

    /// `.localTuned` ветвит ДО реестра: пустой реестр (без единого зарегистрированного
    /// провайдера) — резолв всё равно `.resolved` через мок-строитель, `localTune`
    /// вызван РОВНО с `target.model`.
    func testLocalTunedTargetCallsLocalTuneBuilderWithModelAndSkipsRegistry() {
        let registry = makeRegistry() // пуст — ни один провайдер не зарегистрирован
        let provider = MockChatProvider()
        var receivedModel: String?
        let target = EscalationTarget(providerID: .localTunedProviderID, model: "Qwen2.5-7B-Instruct-4bit", kind: .localTuned)
        let result = EscalationTargetResolver.resolve(target: target, registry: registry, localTune: { model in
            receivedModel = model
            return .resolved(ResolvedChatProvider(provider: provider, model: model,
                                                   providerID: .localTunedProviderID, displayName: "Тюн \(model) (локально)"))
        })
        XCTAssertEqual(receivedModel, "Qwen2.5-7B-Instruct-4bit")
        guard case let .resolved(resolved) = result else { return XCTFail("ожидали resolved") }
        XCTAssertEqual(resolved.model, "Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(resolved.providerID, .localTunedProviderID)
    }

    /// Строитель `localTune` вернул `.unavailable` (нет finished-тюна базы) — причина
    /// прокидывается наружу без изменений.
    func testLocalTunedTargetPropagatesUnavailableFromBuilder() {
        let registry = makeRegistry()
        let target = EscalationTarget(providerID: .localTunedProviderID, model: "Qwen2.5-7B-Instruct-4bit", kind: .localTuned)
        let result = EscalationTargetResolver.resolve(target: target, registry: registry, localTune: { _ in
            .unavailable(reason: "нет тюна базы «Qwen2.5-7B-Instruct-4bit»")
        })
        guard case let .unavailable(reason) = result else { return XCTFail("ожидали unavailable") }
        XCTAssertEqual(reason, "нет тюна базы «Qwen2.5-7B-Instruct-4bit»")
    }

    /// Дефолтный `localTune` (вызывающий не передал строитель) — безопасная деградация
    /// в `.unavailable`, не краш и не фолбэк на реестр.
    func testLocalTunedTargetWithoutInjectedBuilderIsUnavailableByDefault() {
        let registry = makeRegistry()
        let target = EscalationTarget(providerID: .localTunedProviderID, model: "Qwen2.5-7B-Instruct-4bit", kind: .localTuned)
        let result = EscalationTargetResolver.resolve(target: target, registry: registry)
        guard case let .unavailable(reason) = result else { return XCTFail("ожидали unavailable") }
        XCTAssertEqual(reason, "локальная цель не настроена")
    }

    /// `.registry` (дефолт/явный) не зовёт `localTune` вовсе — прежнее поведение задачи 91
    /// не тронуто веткой `.localTuned`.
    func testRegistryKindTargetDoesNotCallLocalTuneBuilder() {
        let registry = makeRegistry()
        registry.register(
            ProviderDescriptor(id: "openai", displayName: "OpenAI", capabilities: [.chat],
                                isLocal: true, defaultModel: "gpt-5"),
            chat: MockChatProvider())
        let target = EscalationTarget(providerID: "openai", model: "", kind: .registry)
        var localTuneCallCount = 0
        let result = EscalationTargetResolver.resolve(target: target, registry: registry, localTune: { _ in
            localTuneCallCount += 1
            return .unavailable(reason: "не должно быть вызвано")
        })
        XCTAssertEqual(localTuneCallCount, 0, ".registry не трогает localTune-строитель")
        guard case let .resolved(resolved) = result else { return XCTFail("ожидали resolved") }
        XCTAssertEqual(resolved.model, "gpt-5")
    }
}
