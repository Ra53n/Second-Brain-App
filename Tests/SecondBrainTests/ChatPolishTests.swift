// ChatPolishTests.swift — тесты полировки чата (задача 23):
// регенерация последнего ответа (canRegenerate-границы, happy path, старый
// ответ не попадает в history запроса, персист) и RAG-биндинги view-модели.

import XCTest
@testable import SecondBrain

@MainActor
final class RegenerateTests: XCTestCase {

    /// Провайдер с фиксированными последовательными ответами (без ручного
    /// управления стримом — регенерации нужен мгновенный второй ответ).
    private final class SequenceProvider: ChatProvider {
        var answers: [String]
        private(set) var receivedMessages: [[ChatMessageDTO]] = []

        init(answers: [String]) { self.answers = answers }

        func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
            ChatResult(text: "не используется", usage: nil)
        }

        func stream(_ messages: [ChatMessageDTO],
                    settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            receivedMessages.append(messages)
            let answer = answers.isEmpty ? "пусто" : answers.removeFirst()
            return AsyncThrowingStream { continuation in
                continuation.yield(.text(answer))
                continuation.finish()
            }
        }
    }

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("regenerate-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func makeViewModel(provider: ChatProvider) -> ChatViewModel {
        let registry = ProviderRegistry()
        registry.register(ProviderDescriptor(id: "mock", displayName: "Mock",
                                             capabilities: [.chat], isLocal: true,
                                             defaultModel: "m"),
                          chat: provider)
        let router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        let viewModel = ChatViewModel(router: router, registry: registry, fileURL: fileURL)
        if let id = viewModel.selectedChatID,
           let index = viewModel.chats.firstIndex(where: { $0.id == id }) {
            viewModel.chats[index].configuration.providerID = "mock"
        }
        return viewModel
    }

    private func waitForGeneration(_ viewModel: ChatViewModel) async throws {
        for _ in 0..<200 where viewModel.selectedChat?.isLoading == true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for _ in 0..<20 { await Task.yield() }
    }

    func testRegenerateReplacesLastAnswer() async throws {
        let provider = SequenceProvider(answers: ["первый ответ", "второй ответ"])
        let viewModel = makeViewModel(provider: provider)

        viewModel.input = "вопрос"
        viewModel.send()
        try await waitForGeneration(viewModel)
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.content, "первый ответ")
        XCTAssertTrue(viewModel.canRegenerate)

        viewModel.regenerateLastAnswer()
        try await waitForGeneration(viewModel)

        let messages = viewModel.selectedChat?.messages ?? []
        XCTAssertEqual(messages.count, 2, "пара «вопрос-ответ» не размножается")
        XCTAssertEqual(messages.last?.content, "второй ответ")
        // Старый ответ не попадает в history повторного запроса.
        let secondRequest = provider.receivedMessages.last ?? []
        XCTAssertFalse(secondRequest.contains { $0.content == "первый ответ" })
        XCTAssertTrue(secondRequest.contains { $0.content == "вопрос" })
    }

    func testRegeneratePersistsResult() async throws {
        let provider = SequenceProvider(answers: ["первый", "второй"])
        let viewModel = makeViewModel(provider: provider)

        viewModel.input = "вопрос"
        viewModel.send()
        try await waitForGeneration(viewModel)
        viewModel.regenerateLastAnswer()
        try await waitForGeneration(viewModel)

        // finishGeneration пишет файл сразу — перечитываем с диска.
        let loaded = ChatPersistence.load(from: fileURL)
        XCTAssertEqual(loaded.first?.messages.last?.content, "второй")
    }

    func testRegenerateKeepsDraftInput() async throws {
        let provider = SequenceProvider(answers: ["первый", "второй"])
        let viewModel = makeViewModel(provider: provider)

        viewModel.input = "вопрос"
        viewModel.send()
        try await waitForGeneration(viewModel)

        viewModel.input = "черновик следующего вопроса"
        viewModel.regenerateLastAnswer()
        try await waitForGeneration(viewModel)
        XCTAssertEqual(viewModel.input, "черновик следующего вопроса",
                       "регенерация не стирает черновик")
    }

    func testCanRegenerateBoundaries() async throws {
        let provider = SequenceProvider(answers: ["ответ"])
        let viewModel = makeViewModel(provider: provider)

        // Пустой чат.
        XCTAssertFalse(viewModel.canRegenerate)

        // Последнее сообщение — пользовательское (ответа ещё нет).
        if let id = viewModel.selectedChatID,
           let index = viewModel.chats.firstIndex(where: { $0.id == id }) {
            viewModel.chats[index].messages.append(ChatMessage(role: .user, content: "вопрос"))
            XCTAssertFalse(viewModel.canRegenerate)

            // Идёт генерация.
            viewModel.chats[index].messages.append(ChatMessage(role: .assistant, content: "ответ"))
            viewModel.chats[index].isLoading = true
            XCTAssertFalse(viewModel.canRegenerate)
            viewModel.chats[index].isLoading = false
            XCTAssertTrue(viewModel.canRegenerate)
        }
    }

    /// Регенерация локального ответа слэш-команды тоже работает (без LLM).
    func testRegenerateLocalSlashAnswer() async throws {
        let provider = SequenceProvider(answers: [])
        let viewModel = makeViewModel(provider: provider)

        viewModel.input = "/help"
        viewModel.send()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(viewModel.canRegenerate)

        viewModel.regenerateLastAnswer()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(viewModel.selectedChat?.messages.count, 2)
        XCTAssertTrue(viewModel.selectedChat?.messages.last?.content
            .contains("Доступные команды") == true)
        XCTAssertTrue(provider.receivedMessages.isEmpty, "LLM не вызывался")
    }
}

// MARK: - RAG-биндинги

@MainActor
final class RagBindingsTests: XCTestCase {

    private func makeViewModel() -> ChatViewModel {
        let registry = ProviderRegistry()
        let router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ragbindings-\(UUID().uuidString).json")
        return ChatViewModel(router: router, registry: registry, fileURL: fileURL)
    }

    func testBindingsRoundTripIntoSelectedChatConfiguration() {
        let viewModel = makeViewModel()

        viewModel.ragTopKBinding = 8
        viewModel.ragMinScoreBinding = 0.35
        viewModel.ragRerankBinding = true
        viewModel.ragQueryRewriteBinding = true

        let config = viewModel.selectedChat?.configuration
        XCTAssertEqual(config?.ragTopK, 8)
        XCTAssertEqual(config?.ragMinScore ?? 0, 0.35, accuracy: 0.0001)
        XCTAssertEqual(config?.ragRerankEnabled, true)
        XCTAssertEqual(config?.ragQueryRewrite, true)

        XCTAssertEqual(viewModel.ragTopKBinding, 8)
        XCTAssertEqual(viewModel.ragMinScoreBinding, 0.35, accuracy: 0.0001)
        XCTAssertTrue(viewModel.ragRerankBinding)
        XCTAssertTrue(viewModel.ragQueryRewriteBinding)
    }

    /// Задача 24: выбор недоступного провайдера сохраняется как переопределение
    /// (пункты меню больше не задизейблены), а ошибка отправки подсказывает путь.
    func testUnavailableProviderSelectableAndErrorHintsSettings() {
        let registry = ProviderRegistry()
        // Провайдер без реализации chat → недоступен для отправки.
        registry.register(ProviderDescriptor(id: "cloud", displayName: "Cloud",
                                             capabilities: [.chat], isLocal: false,
                                             defaultModel: "m-1"),
                          isAvailable: { false })
        let router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unavail-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = ChatViewModel(router: router, registry: registry, fileURL: fileURL)

        viewModel.setModel(providerID: "cloud", model: "m-1")
        XCTAssertEqual(viewModel.selectedChat?.configuration.providerID, "cloud",
                       "выбор сохраняется даже для недоступного провайдера")

        viewModel.input = "вопрос"
        viewModel.send()
        XCTAssertTrue(viewModel.selectedChat?.errorText?.contains("Настройки") == true,
                      "баннер подсказывает, где настроить ключи: \(viewModel.selectedChat?.errorText ?? "nil")")
    }

    func testBindingsWithoutSelectionAreNoOpWithDefaults() {
        let viewModel = makeViewModel()
        viewModel.selectedChatID = nil

        XCTAssertEqual(viewModel.ragTopKBinding, ChatConfiguration().ragTopK)
        XCTAssertEqual(viewModel.ragMinScoreBinding, 0)
        XCTAssertFalse(viewModel.ragRerankBinding)
        XCTAssertFalse(viewModel.ragQueryRewriteBinding)

        // set без выбранного чата — no-op, не крэш.
        viewModel.ragTopKBinding = 9
        viewModel.ragMinScoreBinding = 0.5
        viewModel.ragRerankBinding = true
        viewModel.ragQueryRewriteBinding = true
        XCTAssertEqual(viewModel.chats.first?.configuration.ragTopK, ChatConfiguration().ragTopK)
    }
}
