// ChatTests.swift — задача 12: миграции моделей чата (паттерн MigrationTests),
// PromptBuilder (секции, окно истории), ChatViewModel на MockChatProvider
// (отправка, стриминг по кускам, отмена, ошибка провайдера, автоназвание).

import Combine
import XCTest
@testable import SecondBrain

// MARK: - Миграции моделей

final class ChatModelsTests: XCTestCase {
    var tempDir: URL!
    var fileURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("chats.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTrip() {
        var chat = Chat(title: "Тестовый")
        chat.messages = [
            ChatMessage(role: .user, content: "привет"),
            ChatMessage(role: .assistant, content: "здравствуйте",
                        metrics: MessageMetrics(totalTokens: 42, duration: 1.5))
        ]
        chat.configuration.providerID = "openai"
        chat.configuration.model = "gpt-4o-mini"
        ChatPersistence.save([chat], to: fileURL)
        let loaded = ChatPersistence.load(from: fileURL)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Тестовый")
        XCTAssertEqual(loaded[0].messages.count, 2)
        XCTAssertEqual(loaded[0].messages[1].metrics?.totalTokens, 42)
        XCTAssertEqual(loaded[0].configuration.providerID, "openai")
    }

    func testMigrationFromMinimalJSON() throws {
        // Чат из «старой версии»: только title и одно сообщение без новых полей.
        let json = #"[{"title": "Старый чат", "messages": [{"role": "user", "content": "хм"}]}]"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = ChatPersistence.load(from: fileURL)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Старый чат")
        XCTAssertEqual(loaded[0].messages.first?.content, "хм")
        XCTAssertEqual(loaded[0].configuration, ChatConfiguration(),
                       "нет настроек → дефолтные")
        XCTAssertFalse(loaded[0].isLoading, "runtime-поля не сериализуются")
    }

    func testUnknownRoleFallsBackToAssistant() throws {
        let json = #"[{"messages": [{"role": "tool", "content": "результат"}]}]"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = ChatPersistence.load(from: fileURL)
        XCTAssertEqual(loaded[0].messages.first?.role, .assistant)
    }

    func testCorruptFileQuarantined() throws {
        try Data("{мусор".utf8).write(to: fileURL)
        XCTAssertTrue(ChatPersistence.load(from: fileURL).isEmpty)
        let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRuntimeFieldsNotPersisted() {
        var chat = Chat()
        chat.isLoading = true
        chat.errorText = "ошибка"
        ChatPersistence.save([chat], to: fileURL)
        let loaded = ChatPersistence.load(from: fileURL)
        XCTAssertFalse(loaded[0].isLoading)
        XCTAssertNil(loaded[0].errorText)
    }

    func testMakeTitle() {
        XCTAssertEqual(Chat.makeTitle(from: "Короткий вопрос"), "Короткий вопрос")
        XCTAssertEqual(Chat.makeTitle(from: "Первая строка\nвторая"), "Первая строка")
        XCTAssertEqual(Chat.makeTitle(from: "   "), "Новый чат")
        let long = String(repeating: "и", count: 100)
        XCTAssertTrue(Chat.makeTitle(from: long).hasSuffix("…"))
        XCTAssertLessThanOrEqual(Chat.makeTitle(from: long).count, 41)
    }
}

// MARK: - PromptBuilder

final class ChatPromptBuilderTests: XCTestCase {

    func testSystemPromptWithoutSectionsIsBaseOnly() {
        XCTAssertEqual(ChatPromptBuilder.systemPrompt(), ChatPromptBuilder.basePrompt)
    }

    func testSystemPromptWithRagSection() {
        let prompt = ChatPromptBuilder.systemPrompt(ragContext: "фрагменты из vault")
        XCTAssertTrue(prompt.contains("[RAG_CONTEXT]\nфрагменты из vault"))
        XCTAssertTrue(prompt.hasPrefix(ChatPromptBuilder.basePrompt))
    }

    func testEmptySectionsAreOmitted() {
        XCTAssertFalse(ChatPromptBuilder.systemPrompt(ragContext: "").contains("[RAG_CONTEXT]"))
        XCTAssertFalse(ChatPromptBuilder.systemPrompt(tools: nil).contains("[TOOLS]"))
    }

    func testRequestMessagesApplyHistoryWindow() {
        let history = (1...10).map { ChatMessage(role: $0 % 2 == 0 ? .assistant : .user,
                                                 content: "сообщение \($0)") }
        let messages = ChatPromptBuilder.requestMessages(history: history, historyWindow: 4)
        // 1 системное + 4 последних.
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[1].content, "сообщение 7")
        XCTAssertEqual(messages.last?.content, "сообщение 10")
    }

    func testRequestMessagesSkipEmptyContent() {
        let history = [ChatMessage(role: .user, content: "вопрос"),
                       ChatMessage(role: .assistant, content: "")]
        let messages = ChatPromptBuilder.requestMessages(history: history, historyWindow: 10)
        XCTAssertEqual(messages.count, 2, "пустая заглушка не уходит в API")
    }
}

// MARK: - ViewModel на моках

/// Провайдер с управляемым стримом: тест сам решает, когда выдать кусок/ошибку.
private final class ScriptedChatProvider: ChatProvider {
    var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private(set) var receivedMessages: [[ChatMessageDTO]] = []

    func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
        receivedMessages.append(messages)
        return ChatResult(text: "не используется", usage: nil)
    }

    func stream(_ messages: [ChatMessageDTO],
                settings: ChatSettings) -> AsyncThrowingStream<String, Error> {
        receivedMessages.append(messages)
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
final class ChatViewModelTests: XCTestCase {
    var tempDir: URL!
    var fileURL: URL!
    var registry: ProviderRegistry!
    var router: FunctionRouter!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("chats.json")
        registry = ProviderRegistry()
        router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func register(_ provider: ChatProvider, id: ProviderID = "mock") {
        registry.register(
            ProviderDescriptor(id: id, displayName: "Mock",
                               capabilities: [.chat], isLocal: true, defaultModel: "m-1"),
            chat: provider)
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(router: router, registry: registry, fileURL: fileURL)
    }

    /// Ждём выполнения запланированных MainActor-тасков (стриминг идёт через Task).
    private func drainMainQueue() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testSendAppendsUserAndStreamsAssistant() async throws {
        let provider = ScriptedChatProvider()
        register(provider)
        let vm = makeViewModel()
        vm.input = "Привет, модель"
        vm.send()
        await drainMainQueue()

        // Автоназвание из первого сообщения.
        XCTAssertEqual(vm.selectedChat?.title, "Привет, модель")
        XCTAssertEqual(vm.selectedChat?.messages.count, 2, "user + заглушка ассистента")
        XCTAssertEqual(vm.selectedChat?.isLoading, true)

        // Стриминг по кускам.
        provider.continuation?.yield("Здрав")
        await drainMainQueue()
        XCTAssertEqual(vm.selectedChat?.messages.last?.content, "Здрав")
        provider.continuation?.yield("ствуйте!")
        await drainMainQueue()
        XCTAssertEqual(vm.selectedChat?.messages.last?.content, "Здравствуйте!")

        provider.continuation?.finish()
        await drainMainQueue()
        XCTAssertEqual(vm.selectedChat?.isLoading, false)
        XCTAssertNotNil(vm.selectedChat?.messages.last?.metrics, "метрики после завершения")
        // Финальное состояние записано на диск немедленно.
        let onDisk = ChatPersistence.load(from: fileURL)
        XCTAssertEqual(onDisk.first?.messages.last?.content, "Здравствуйте!")
    }

    func testCancelKeepsPartialAnswer() async throws {
        let provider = ScriptedChatProvider()
        register(provider)
        let vm = makeViewModel()
        vm.input = "вопрос"
        vm.send()
        await drainMainQueue()
        provider.continuation?.yield("Частичный отв")
        await drainMainQueue()

        vm.cancelGeneration(chatID: vm.selectedChatID!)
        provider.continuation?.finish() // стрим рвётся отменой Task
        await drainMainQueue()

        XCTAssertEqual(vm.selectedChat?.isLoading, false)
        XCTAssertEqual(vm.selectedChat?.messages.last?.content, "Частичный отв",
                       "частичный ответ сохраняется")
        XCTAssertNil(vm.selectedChat?.errorText, "отмена — не ошибка")
    }

    func testProviderErrorShowsBannerAndRemovesEmptyPlaceholder() async throws {
        let provider = ScriptedChatProvider()
        register(provider)
        let vm = makeViewModel()
        vm.input = "вопрос"
        vm.send()
        await drainMainQueue()

        provider.continuation?.finish(throwing: LLMError.badStatus(code: 500, message: "сервер лёг"))
        await drainMainQueue()

        XCTAssertEqual(vm.selectedChat?.isLoading, false)
        XCTAssertNotNil(vm.selectedChat?.errorText)
        XCTAssertTrue(vm.selectedChat?.errorText?.contains("500") ?? false)
        XCTAssertEqual(vm.selectedChat?.messages.count, 1,
                       "пустая заглушка убрана, user-сообщение осталось")
    }

    func testNoProviderShowsError() async {
        let vm = makeViewModel() // реестр пуст
        vm.input = "вопрос"
        vm.send()
        await drainMainQueue()
        XCTAssertNotNil(vm.selectedChat?.errorText)
        XCTAssertEqual(vm.selectedChat?.isLoading, false)
    }

    func testPerChatModelOverrideUsedInsteadOfRouter() async throws {
        let routed = ScriptedChatProvider()
        let override = ScriptedChatProvider()
        register(routed, id: "routed")
        register(override, id: "override")
        let vm = makeViewModel()
        vm.setModel(providerID: "override", model: "special-model")
        vm.input = "вопрос"
        vm.send()
        await drainMainQueue()

        XCTAssertEqual(override.receivedMessages.count, 1, "выбран override-провайдер")
        XCTAssertEqual(routed.receivedMessages.count, 0)
        override.continuation?.finish()
    }

    func testHistoryWindowLimitsRequest() async throws {
        let provider = ScriptedChatProvider()
        register(provider)
        let vm = makeViewModel()
        // Наполняем историю напрямую.
        var chat = vm.selectedChat!
        chat.messages = (1...30).map { ChatMessage(role: $0 % 2 == 0 ? .assistant : .user,
                                                   content: "старое \($0)") }
        chat.configuration.historyWindow = 6
        vm.chats[0] = chat

        vm.input = "новый вопрос"
        vm.send()
        await drainMainQueue()

        let sent = provider.receivedMessages.first ?? []
        // 1 системное + окно 6 (в т.ч. новый вопрос).
        XCTAssertEqual(sent.count, 7)
        XCTAssertEqual(sent.last?.content, "новый вопрос")
        provider.continuation?.finish()
    }
}
