// AgentOrchestratorTests.swift — задача 35: оркестратор FSM-прогона на
// скриптованном провайдере (паттерн ChatViewModelTests): полный прогон с
// тегированными сообщениями и персистом, resume после «краша» (normalize
// running → paused), ошибка → failed, пауза отменой, gen-защита сброса.

import XCTest
@testable import SecondBrain

/// Провайдер с очередью готовых ответов: каждый send снимает следующий.
private final class QueuedChatProvider: ChatProvider {
    var responses: [Result<String, Error>]
    private(set) var requests: [[ChatMessageDTO]] = []

    init(_ responses: [Result<String, Error>]) { self.responses = responses }

    func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
        requests.append(messages)
        guard !responses.isEmpty else {
            throw LLMError.emptyResponse
        }
        let text = try responses.removeFirst().get()
        return ChatResult(text: text,
                          usage: ChatUsage(promptTokens: 3, completionTokens: 4, totalTokens: 7))
    }

    func stream(_ messages: [ChatMessageDTO],
                settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.emptyResponse) }
    }
}

/// Провайдер, «висящий» в запросе: для тестов паузы/сброса посреди фазы.
private final class HangingChatProvider: ChatProvider {
    func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return ChatResult(text: "слишком поздно", usage: nil)
    }

    func stream(_ messages: [ChatMessageDTO],
                settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
final class AgentOrchestratorTests: XCTestCase {
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

    private func register(_ provider: ChatProvider) {
        registry.register(
            ProviderDescriptor(id: "mock", displayName: "Mock",
                               capabilities: [.chat], isLocal: true, defaultModel: "m-1"),
            chat: provider)
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(router: router, registry: registry, fileURL: fileURL)
    }

    private func drainMainQueue() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Дожидается завершения активного прогона выбранного чата.
    private func awaitRun(_ vm: ChatViewModel, chatID: UUID) async {
        await vm.agentTasks[chatID]?.value
        await drainMainQueue()
    }

    // MARK: - Полный прогон

    func testFullRunProducesTaggedMessagesAndPersists() async throws {
        let provider = QueuedChatProvider([
            .success("1. раз\n2. два"),
            .success("результат раз\nNEXT_STEP"),
            .success("результат два\nNEXT_STEP"),
            .success("всё сходится\nВЕРДИКТ: ВЫПОЛНЕНО"),
            .success("Итоговый ответ"),
        ])
        register(provider)
        let vm = makeViewModel()
        let chatID = vm.selectedChatID!
        vm.chats[0].configuration.agentModeEnabled = true

        vm.input = "сделай двухшаговую задачу"
        vm.send()
        await awaitRun(vm, chatID: chatID)

        let chat = vm.selectedChat!
        XCTAssertEqual(chat.messages.count, 6, "user + 5 фаз")
        XCTAssertEqual(chat.messages[0].role, .user)
        XCTAssertEqual(chat.messages[1].agentState, .planning)
        XCTAssertEqual(chat.messages[2].agentState, .execution)
        XCTAssertEqual(chat.messages[2].agentStep, 0)
        XCTAssertEqual(chat.messages[2].agentTotal, 2)
        XCTAssertEqual(chat.messages[2].content, "результат раз", "маркер счищен")
        XCTAssertEqual(chat.messages[3].agentStep, 1)
        XCTAssertEqual(chat.messages[4].agentState, .validation)
        XCTAssertEqual(chat.messages[5].agentState, .answer)
        XCTAssertEqual(chat.messages[5].content, "Итоговый ответ")
        XCTAssertEqual(chat.messages[5].metrics?.totalTokens, 7)
        XCTAssertEqual(chat.messages[5].metrics?.model, "m-1")

        XCTAssertEqual(chat.agentContext?.status, .finished)
        XCTAssertEqual(chat.agentContext?.answer, "Итоговый ответ")
        XCTAssertEqual(chat.agentContext?.done, ["результат раз", "результат два"])
        XCTAssertFalse(chat.isLoading)

        // Роли этапов уходили в системный промпт (жёсткая FSM «на уровне кода»).
        XCTAssertEqual(provider.requests.count, 5)
        XCTAssertTrue(provider.requests[0][0].content.contains("планировщик"))
        XCTAssertTrue(provider.requests[1][0].content.contains("исполнитель"))
        XCTAssertTrue(provider.requests[3][0].content.contains("проверяющий"))
        XCTAssertTrue(provider.requests[4][0].content.contains("ФИНАЛЬНЫЙ ОТВЕТ"))

        // Финальное состояние на диске.
        let onDisk = ChatPersistence.load(from: fileURL)
        XCTAssertEqual(onDisk.first?.agentContext?.status, .finished)
        XCTAssertEqual(onDisk.first?.messages.count, 6)
    }

    // MARK: - Resume после «краша»

    func testCrashedRunNormalizesToPausedAndResumeCompletes() async throws {
        // chats.json середины прогона: выполнение, шаг 2/2, status=running
        // (приложение «убили» посреди фазы).
        var chat = Chat(title: "resume")
        chat.configuration.agentModeEnabled = true
        chat.messages = [ChatMessage(role: .user, content: "задача")]
        var ctx = AgentTaskContext(task: "задача")
        ctx.state = .execution
        ctx.status = .running
        ctx.plan = ["раз", "два"]
        ctx.done = ["результат раз"]
        ctx.step = 1
        ctx.total = 2
        chat.agentContext = ctx
        ChatPersistence.save([chat], to: fileURL)

        let provider = QueuedChatProvider([
            .success("результат два\nNEXT_STEP"),
            .success("ВЕРДИКТ: ВЫПОЛНЕНО"),
            .success("Ответ после resume"),
        ])
        register(provider)
        let vm = makeViewModel()

        // Normalize на старте: зависший running → paused.
        XCTAssertEqual(vm.chats[0].agentContext?.status, .paused)

        vm.resumeAgentRun(chatID: chat.id)
        await awaitRun(vm, chatID: chat.id)

        XCTAssertEqual(vm.chats[0].agentContext?.status, .finished)
        XCTAssertEqual(vm.chats[0].agentContext?.answer, "Ответ после resume")
        XCTAssertEqual(provider.requests.count, 3,
                       "resume продолжил с шага 2, а не с начала")
        XCTAssertTrue(provider.requests[0].last!.content.contains("[CURRENT]  два"))
    }

    // MARK: - Ошибка провайдера

    func testProviderErrorFailsRunAndKeepsState() async throws {
        struct BoomError: LocalizedError {
            var errorDescription: String? { "взорвалось" }
        }
        let provider = QueuedChatProvider([.failure(BoomError())])
        register(provider)
        let vm = makeViewModel()
        let chatID = vm.selectedChatID!
        vm.chats[0].configuration.agentModeEnabled = true

        vm.input = "задача"
        vm.send()
        await awaitRun(vm, chatID: chatID)

        XCTAssertEqual(vm.chats[0].agentContext?.status, .failed)
        XCTAssertEqual(vm.chats[0].agentContext?.state, .planning,
                       "этап не потерян — «Продолжить» повторит его")
        XCTAssertEqual(vm.chats[0].errorText, "взорвалось")
        XCTAssertFalse(vm.chats[0].isLoading)
        // Состояние сохранено для возобновления.
        XCTAssertEqual(ChatPersistence.load(from: fileURL).first?.agentContext?.status, .failed)

        // Возобновление из failed доводит прогон до конца.
        provider.responses = [
            .success("1. единственный шаг"),
            .success("сделано\nNEXT_STEP"),
            .success("ВЕРДИКТ: ВЫПОЛНЕНО"),
            .success("Ответ"),
        ]
        vm.resumeAgentRun(chatID: chatID)
        await awaitRun(vm, chatID: chatID)
        XCTAssertEqual(vm.chats[0].agentContext?.status, .finished)
    }

    // MARK: - Пауза и сброс

    func testPauseMidPhaseKeepsStageForResume() async throws {
        register(HangingChatProvider())
        let vm = makeViewModel()
        let chatID = vm.selectedChatID!
        vm.chats[0].configuration.agentModeEnabled = true

        vm.input = "задача"
        vm.send()
        await drainMainQueue()
        XCTAssertEqual(vm.chats[0].agentContext?.status, .running)

        vm.pauseAgentRun(chatID: chatID)
        await awaitRun(vm, chatID: chatID)

        XCTAssertEqual(vm.chats[0].agentContext?.status, .paused,
                       "отмена — пауза, не ошибка")
        XCTAssertEqual(vm.chats[0].agentContext?.state, .planning,
                       "этап/шаг не тронуты — resume повторит фазу")
        XCTAssertNil(vm.chats[0].errorText)
        XCTAssertFalse(vm.chats[0].isLoading)
    }

    func testResetInvalidatesOldRun() async throws {
        register(HangingChatProvider())
        let vm = makeViewModel()
        let chatID = vm.selectedChatID!
        vm.chats[0].configuration.agentModeEnabled = true

        vm.input = "задача"
        vm.send()
        await drainMainQueue()
        let oldTask = vm.agentTasks[chatID]

        vm.resetAgentRun(chatID: chatID)
        XCTAssertNil(vm.chats[0].agentContext)

        // Доигрывающий отменённый Task не воскрешает состояние (gen-защита).
        await oldTask?.value
        await drainMainQueue()
        XCTAssertNil(vm.chats[0].agentContext)
        XCTAssertFalse(vm.chats[0].isLoading)
    }

    // MARK: - Awaitable-хуки для пайплайнов (задача 36)

    func testRunAgentToCompletionAwaitsRealFinish() async throws {
        let provider = QueuedChatProvider([
            .success("1. единственный шаг"),
            .success("сделано\nNEXT_STEP"),
            .success("ВЕРДИКТ: ВЫПОЛНЕНО"),
            .success("Готовый ответ"),
        ])
        register(provider)
        let vm = makeViewModel()

        let status = await vm.runAgentToCompletion(chatIndex: 0, userText: "задача")

        XCTAssertEqual(status, .finished, "статус возвращается ПОСЛЕ завершения прогона")
        XCTAssertEqual(provider.requests.count, 4, "все фазы отработали до возврата")
        XCTAssertEqual(vm.chats[0].messages.last?.content, "Готовый ответ")
        XCTAssertFalse(vm.chats[0].isLoading)
    }

    func testRunAgentToCompletionProviderErrorReturnsFailed() async throws {
        struct BoomError: LocalizedError {
            var errorDescription: String? { "взорвалось" }
        }
        register(QueuedChatProvider([.failure(BoomError())]))
        let vm = makeViewModel()

        let status = await vm.runAgentToCompletion(chatIndex: 0, userText: "задача")
        XCTAssertEqual(status, .failed)
        XCTAssertEqual(vm.chats[0].agentContext?.errorText, "взорвалось")
    }

    func testRunAgentToCompletionNoProviderReturnsFailed() async throws {
        // Провайдер не зарегистрирован: startAgentRun выходит без Task.
        let vm = makeViewModel()
        let status = await vm.runAgentToCompletion(chatIndex: 0, userText: "задача")
        XCTAssertEqual(status, .failed)
        XCTAssertNotNil(vm.chats[0].errorText)
    }

    func testRunSingleTurnToCompletionReturnsNilOnSuccess() async throws {
        register(MockChatProvider(responses: ["Ответ одним запросом"]))
        let vm = makeViewModel()

        let error = await vm.runSingleTurnToCompletion(chatIndex: 0, userText: "вопрос")

        XCTAssertNil(error)
        // Мок стримит по словам с хвостовым пробелом — сравниваем без него.
        XCTAssertEqual(vm.chats[0].messages.last?.content
                        .trimmingCharacters(in: .whitespaces),
                       "Ответ одним запросом")
        XCTAssertFalse(vm.chats[0].isLoading)
    }

    func testRunSingleTurnToCompletionReturnsErrorText() async throws {
        let provider = MockChatProvider(responses: ["не дойдёт"])
        provider.errorToThrow = LLMError.emptyResponse
        register(provider)
        let vm = makeViewModel()

        let error = await vm.runSingleTurnToCompletion(chatIndex: 0, userText: "вопрос")
        XCTAssertNotNil(error, "ошибка провайдера возвращается движку пайплайна")
    }

    // MARK: - displayText (задача 37)

    func testDisplayTextShownWhileFullTaskDrivesRun() async throws {
        let provider = QueuedChatProvider([
            .success("1. единственный шаг"),
            .success("сделано\nNEXT_STEP"),
            .success("ВЕРДИКТ: ВЫПОЛНЕНО"),
            .success("Ответ"),
        ])
        register(provider)
        let vm = makeViewModel()
        let hugeTask = "Проревьюй diff:\n" + String(repeating: "x", count: 5_000)

        let status = await vm.runAgentToCompletion(chatIndex: 0, userText: hugeTask,
                                                   displayText: "Ревью PR #42: фикс")
        XCTAssertEqual(status, .finished)
        // В ленте и тайтле — короткая версия, в контексте прогона — полная.
        XCTAssertEqual(vm.chats[0].messages.first?.content, "Ревью PR #42: фикс")
        XCTAssertEqual(vm.chats[0].title, "Ревью PR #42: фикс")
        XCTAssertEqual(vm.chats[0].agentContext?.task, hugeTask)
        XCTAssertEqual(vm.chats[0].agentContext?.displayText, "Ревью PR #42: фикс")
        // Полный task ушёл модели в [QUERY] фазы планирования.
        XCTAssertTrue(provider.requests[0].last!.content.contains("Проревьюй diff:"))
        // Короткая версия не течёт в [КОНТЕКСТ ДИАЛОГА] (последнее user-сообщение
        // вырезается из снапшота и при displayText).
        XCTAssertFalse(provider.requests[0].last!.content.contains("[КОНТЕКСТ ДИАЛОГА]"))
    }

    // MARK: - Обычный режим не затронут

    func testAgentModeOffUsesPlainGeneration() async throws {
        let provider = QueuedChatProvider([.success("не должен вызываться")])
        register(provider)
        let vm = makeViewModel()
        XCTAssertFalse(vm.chats[0].configuration.agentModeEnabled, "дефолт — один запрос")

        vm.input = "обычный вопрос"
        vm.send()
        await drainMainQueue()

        XCTAssertNil(vm.chats[0].agentContext, "FSM-контекст не создаётся")
        XCTAssertTrue(provider.requests.isEmpty, "send() FSM-путь не трогал")
    }
}
