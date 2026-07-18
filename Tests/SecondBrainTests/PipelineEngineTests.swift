// PipelineEngineTests.swift — движок пайплайнов (задача 36) на скриптованном
// провайдере (паттерн AgentOrchestratorTests): рендер шаблона и сообщения в
// destination-чате (fsm и single), автосоздание чата, запись PipelineRun с
// токенами, running-запись на диске ДО завершения, overlap → skippedOverlap,
// ошибка провайдера → error.

import XCTest
@testable import SecondBrain

@MainActor
final class PipelineEngineTests: XCTestCase {
    var tempDir: URL!
    var registry: ProviderRegistry!
    var router: FunctionRouter!
    var chatVM: ChatViewModel!
    var store: PipelineStore!
    var engine: PipelineEngine!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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

    private func makeEngine() {
        chatVM = ChatViewModel(router: router, registry: registry,
                               fileURL: tempDir.appendingPathComponent("chats.json"))
        store = PipelineStore(pipelinesURL: tempDir.appendingPathComponent("pipelines.json"),
                              runsURL: tempDir.appendingPathComponent("pipeline-runs.json"))
        engine = PipelineEngine(store: store, chatViewModel: chatVM)
    }

    /// Ответы полного FSM-прогона с одним шагом плана.
    private var fsmResponses: [String] {
        ["1. единственный шаг",
         "сделано\nNEXT_STEP",
         "ВЕРДИКТ: ВЫПОЛНЕНО",
         "Ответ пайплайна"]
    }

    // MARK: - FSM-прогон

    func testFSMRunWritesMessagesAndRun() async throws {
        register(MockChatProvider(responses: fsmResponses))
        makeEngine()
        var pipeline = PipelineConfig(name: "Дайджест")
        pipeline.inputTemplate = "Обработай: {{trigger_payload}}"
        pipeline.agentMode = .fsm
        store.add(pipeline)

        let run = await engine.run(pipeline, trigger: .manual, payload: "PR #7")

        XCTAssertEqual(run.status, .ok)
        XCTAssertEqual(run.trigger, .manual)
        XCTAssertEqual(run.payloadSummary, "PR #7")
        XCTAssertNotNil(run.finishedAt)

        // Destination-чат создан автоматически и записан в конфиг.
        let chatID = try XCTUnwrap(run.destinationChatID)
        XCTAssertEqual(store.pipeline(id: pipeline.id)?.destinationChatID, chatID)
        let chat = try XCTUnwrap(chatVM.chats.first { $0.id == chatID })
        XCTAssertEqual(chat.title, "Пайплайн: Дайджест")

        // Шаблон отрендерен в сообщение пользователя, фазы дошли до ответа.
        XCTAssertEqual(chat.messages.first?.content, "Обработай: PR #7")
        XCTAssertEqual(chat.messages.last?.agentState, .answer)
        XCTAssertEqual(chat.messages.last?.content, "Ответ пайплайна")
        XCTAssertEqual(run.resultMessageID, chat.messages.last?.id)

        // Токены прогона = сумма метрик фазовых сообщений.
        let expectedTotal = chat.messages.compactMap { $0.metrics?.totalTokens }.reduce(0, +)
        XCTAssertEqual(run.totalTokens, expectedTotal)
        XCTAssertNotNil(run.promptTokens)

        // toolSelection перенесён в конфигурацию чата.
        XCTAssertTrue(chat.configuration.agentModeEnabled)
        XCTAssertFalse(chat.configuration.ragEnabled, "баз нет — RAG выключен")
    }

    func testSingleRunWritesAnswer() async throws {
        register(MockChatProvider(responses: ["Ответ одним запросом"]))
        makeEngine()
        var pipeline = PipelineConfig(name: "Одиночный")
        pipeline.inputTemplate = "Вопрос"
        pipeline.agentMode = .single
        store.add(pipeline)

        let run = await engine.run(pipeline, trigger: .manual)

        XCTAssertEqual(run.status, .ok)
        let chat = try XCTUnwrap(chatVM.chats.first { $0.id == run.destinationChatID })
        XCTAssertFalse(chat.configuration.agentModeEnabled)
        XCTAssertEqual(chat.messages.count, 2, "вопрос + ответ")
        XCTAssertEqual(chat.messages.last?.content.trimmingCharacters(in: .whitespaces),
                       "Ответ одним запросом")
        XCTAssertEqual(run.resultMessageID, chat.messages.last?.id)
    }

    func testExistingDestinationChatReused() async throws {
        register(MockChatProvider(responses: fsmResponses))
        makeEngine()
        let existing = chatVM.chats[0].id
        var pipeline = PipelineConfig(name: "В существующий")
        pipeline.destinationChatID = existing
        store.add(pipeline)

        let run = await engine.run(pipeline, trigger: .manual)

        XCTAssertEqual(run.destinationChatID, existing)
        XCTAssertEqual(chatVM.chats.count, 1, "новый чат не создавался")
    }

    // MARK: - Overlap guard

    func testSecondRunWhileFirstAliveIsSkippedOverlap() async throws {
        let provider = MockChatProvider(responses: fsmResponses)
        provider.delay = 0.3 // первый прогон «висит» в фазе
        register(provider)
        makeEngine()
        let pipeline = PipelineConfig(name: "Занятой")
        store.add(pipeline)

        let first = Task { await self.engine.run(pipeline, trigger: .cron) }
        // Даём первому прогону дойти до overlap guard и стартовать LLM-фазу.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(engine.runningPipelineIDs.contains(pipeline.id))

        let second = await engine.run(pipeline, trigger: .manual)
        XCTAssertEqual(second.status, .skippedOverlap)
        XCTAssertEqual(second.errorText, "Предыдущий прогон ещё выполняется.")
        XCTAssertEqual(second.finishedAt, second.startedAt, "мгновенный финал, прогона не было")

        let firstRun = await first.value
        XCTAssertEqual(firstRun.status, .ok, "первый прогон дошёл до конца")
        XCTAssertEqual(store.runs.filter { $0.status == .skippedOverlap }.count, 1)
    }

    func testBusyDestinationChatIsSkippedOverlap() async throws {
        register(MockChatProvider(responses: fsmResponses))
        makeEngine()
        var pipeline = PipelineConfig(name: "В занятый чат")
        pipeline.destinationChatID = chatVM.chats[0].id
        store.add(pipeline)
        chatVM.chats[0].isLoading = true // пользовательская генерация в чате

        let run = await engine.run(pipeline, trigger: .manual)
        XCTAssertEqual(run.status, .skippedOverlap)
        XCTAssertEqual(run.errorText, "Чат назначения занят другой генерацией.")
    }

    // MARK: - Ошибки и crash-safety

    func testProviderErrorFinalizesRunAsError() async throws {
        struct BoomError: LocalizedError {
            var errorDescription: String? { "взорвалось" }
        }
        let provider = MockChatProvider(responses: ["не дойдёт"])
        provider.errorToThrow = BoomError()
        register(provider)
        makeEngine()
        let pipeline = PipelineConfig(name: "Сломанный")
        store.add(pipeline)

        let run = await engine.run(pipeline, trigger: .cron)
        XCTAssertEqual(run.status, .error)
        XCTAssertEqual(run.errorText, "взорвалось")
        XCTAssertNotNil(run.finishedAt)
    }

    func testNoProviderFinalizesRunAsError() async throws {
        // Провайдер вообще не зарегистрирован.
        makeEngine()
        let pipeline = PipelineConfig(name: "Без провайдера")
        store.add(pipeline)

        let run = await engine.run(pipeline, trigger: .manual)
        XCTAssertEqual(run.status, .error)
        XCTAssertNotNil(run.errorText)
    }

    func testRunningRecordOnDiskBeforeCompletion() async throws {
        let provider = MockChatProvider(responses: fsmResponses)
        provider.delay = 0.3
        register(provider)
        makeEngine()
        let pipeline = PipelineConfig(name: "Crash-safety")
        store.add(pipeline)
        let runsURL = tempDir.appendingPathComponent("pipeline-runs.json")

        let task = Task { await self.engine.run(pipeline, trigger: .manual) }
        for _ in 0..<20 { await Task.yield() }

        // running-запись уже на диске — рестарт посреди прогона оставит след.
        let onDisk = PipelinePersistence.loadRuns(from: runsURL)
        XCTAssertEqual(onDisk.first?.status, .running,
                       "запись создаётся ДО вызова LLM и сразу пишется на диск")

        let finished = await task.value
        XCTAssertEqual(finished.status, .ok)
        XCTAssertEqual(PipelinePersistence.loadRuns(from: runsURL).first?.status, .ok)
    }

    // MARK: - toolSelection

    func testSelectionOverwritesChatConfigurationOwnFieldsOnly() async throws {
        register(MockChatProvider(responses: ["ответ"]))
        makeEngine()
        chatVM.chats[0].configuration.temperature = 0.3      // чужое поле — не трогаем
        chatVM.chats[0].configuration.projectToolsEnabled = true // наше — перезапишем
        chatVM.chats[0].configuration.enabledKnowledgeBaseIDs = ["vault"]
        var pipeline = PipelineConfig(name: "Селекция")
        pipeline.destinationChatID = chatVM.chats[0].id
        pipeline.agentMode = .single
        pipeline.projectToolsEnabled = false
        pipeline.enabledKnowledgeBaseIDs = []
        store.add(pipeline)

        _ = await engine.run(pipeline, trigger: .manual)

        let config = chatVM.chats[0].configuration
        XCTAssertEqual(config.temperature, 0.3, "не-пайплайновые поля сохранены")
        XCTAssertFalse(config.projectToolsEnabled, "поле пайплайна перезаписано")
        XCTAssertTrue(config.enabledKnowledgeBaseIDs.isEmpty)
        XCTAssertFalse(config.ragEnabled, "пустой набор баз выключает RAG")
    }
}
