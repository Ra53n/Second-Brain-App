// ApprovalFlowTests.swift — тесты approve-гейта (задача 39).
//
// Скриптованный провайдер просит вызовы инструментов; гейт в ChatToolAssembly
// классифицирует их и в режиме «Спрашивать» публикует PendingToolApproval,
// цикл ждёт решения. Тесты резолвят карточку кнопками (allowOnce /
// allowSession / deny) и проверяют: исполнение после разрешения, ERROR после
// отказа, «на сессию» не спрашивает повторно, отмена хода гасит ожидание,
// safe-вызовы идут без вопросов.

import XCTest
@testable import SecondBrain

@MainActor
final class ApprovalFlowTests: XCTestCase {

    /// Провайдер по сценарию: последовательность шагов из tool-вызовов,
    /// затем финальный текст.
    private final class ScriptedProvider: ChatProvider, ToolCapableChatProvider {
        private var steps: [[ToolCallRequest]]
        private var index = 0

        init(steps: [[ToolCallRequest]]) { self.steps = steps }

        func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
            ChatResult(text: "не используется", usage: nil)
        }

        func stream(_ messages: [ChatMessageDTO],
                    settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func sendWithTools(_ messages: [ToolAwareMessage],
                           settings: ChatSettings,
                           tools: [ToolDefinition],
                           forceText: Bool) async throws -> ToolLoopStep {
            defer { index += 1 }
            if index < steps.count {
                return ToolLoopStep(text: nil, toolCalls: steps[index], usage: nil)
            }
            return ToolLoopStep(text: "готово", toolCalls: [], usage: nil)
        }
    }

    private var fileURL: URL!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-tests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func makeViewModel(provider: ChatProvider,
                               mode: AgentPermissionMode) -> (ChatViewModel, () -> [String]) {
        let registry = ProviderRegistry()
        registry.register(ProviderDescriptor(id: "scripted", displayName: "Scripted",
                                             capabilities: [.chat], isLocal: true,
                                             defaultModel: "m"),
                          chat: provider)
        let router = FunctionRouter(registry: registry)
        let viewModel = ChatViewModel(router: router, registry: registry, fileURL: fileURL)

        var executed: [String] = []
        viewModel.projectToolsBridge = ChatViewModel.ProjectToolsBridge(
            available: { _ in true },
            tools: { _ in [
                ToolDefinition(name: "write_file", description: "запись",
                               schema: ToolSchemas.empty),
                ToolDefinition(name: "git_status", description: "статус",
                               schema: ToolSchemas.empty)
            ] },
            rootURL: { _ in FileManager.default.temporaryDirectory },
            execute: { _, name, _, _ in executed.append(name); return "OK" })

        if let id = viewModel.selectedChatID,
           let index = viewModel.chats.firstIndex(where: { $0.id == id }) {
            viewModel.chats[index].configuration.providerID = "scripted"
            viewModel.chats[index].configuration.projectToolsEnabled = true
            viewModel.chats[index].configuration.permissionMode = mode
        }
        return (viewModel, { executed })
    }

    /// Ждём появления карточки approve (или конца генерации).
    private func waitForApproval(_ viewModel: ChatViewModel) async throws {
        for _ in 0..<200 where viewModel.pendingToolApprovals.isEmpty
            && viewModel.selectedChat?.isLoading == true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitForGeneration(_ viewModel: ChatViewModel) async throws {
        for _ in 0..<200 where viewModel.selectedChat?.isLoading == true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for _ in 0..<20 { await Task.yield() }
    }

    private let writeCall = ToolCallRequest(
        id: "1", name: "write_file",
        argumentsJSON: #"{"path":"a.md","content":"x"}"#)

    func testAskModeExecutesAfterAllowOnce() async throws {
        let provider = ScriptedProvider(steps: [[writeCall]])
        let (viewModel, executed) = makeViewModel(provider: provider, mode: .ask)

        viewModel.input = "создай файл"
        viewModel.send()
        try await waitForApproval(viewModel)

        XCTAssertEqual(viewModel.pendingToolApprovals.count, 1)
        XCTAssertEqual(viewModel.pendingToolApprovals[0].toolName, "write_file")
        XCTAssertEqual(viewModel.pendingToolApprovals[0].risk, .write)
        viewModel.resolveToolApproval(id: viewModel.pendingToolApprovals[0].id,
                                      decision: .allowOnce)
        try await waitForGeneration(viewModel)

        XCTAssertEqual(executed(), ["write_file"])
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.content, "готово")
        XCTAssertTrue(viewModel.pendingToolApprovals.isEmpty)
    }

    func testAskModeDenyReturnsErrorToModel() async throws {
        let provider = ScriptedProvider(steps: [[writeCall]])
        let (viewModel, executed) = makeViewModel(provider: provider, mode: .ask)

        viewModel.input = "создай файл"
        viewModel.send()
        try await waitForApproval(viewModel)
        viewModel.resolveToolApproval(id: viewModel.pendingToolApprovals[0].id,
                                      decision: .deny)
        try await waitForGeneration(viewModel)

        XCTAssertTrue(executed().isEmpty, "инструмент не должен исполняться")
        let calls = viewModel.selectedChat?.messages.last?.toolCalls ?? []
        XCTAssertEqual(calls.first?.ok, false)
        XCTAssertTrue(calls.first?.result.contains("отклонил") == true, calls.first?.result ?? "")
    }

    /// «На сессию»: второй такой же вызов исполняется без карточки.
    func testAllowSessionSkipsSecondApproval() async throws {
        let second = ToolCallRequest(id: "2", name: "write_file",
                                     argumentsJSON: #"{"path":"b.md","content":"y"}"#)
        let provider = ScriptedProvider(steps: [[writeCall], [second]])
        let (viewModel, executed) = makeViewModel(provider: provider, mode: .ask)

        viewModel.input = "создай два файла"
        viewModel.send()
        try await waitForApproval(viewModel)
        XCTAssertEqual(viewModel.pendingToolApprovals.count, 1)
        viewModel.resolveToolApproval(id: viewModel.pendingToolApprovals[0].id,
                                      decision: .allowSession)
        try await waitForGeneration(viewModel)

        // Оба вызова исполнены, карточка была ровно одна.
        XCTAssertEqual(executed(), ["write_file", "write_file"])
        XCTAssertTrue(viewModel.pendingToolApprovals.isEmpty)
    }

    /// Safe-вызов в режиме «Спрашивать» идёт без карточки.
    func testSafeCallNeedsNoApprovalInAskMode() async throws {
        let statusCall = ToolCallRequest(id: "1", name: "git_status", argumentsJSON: "{}")
        let provider = ScriptedProvider(steps: [[statusCall]])
        let (viewModel, executed) = makeViewModel(provider: provider, mode: .ask)

        viewModel.input = "статус?"
        viewModel.send()
        try await waitForGeneration(viewModel)

        XCTAssertEqual(executed(), ["git_status"])
        XCTAssertTrue(viewModel.pendingToolApprovals.isEmpty)
    }

    /// «Авто-опасный»: даже dangerous-вызов идёт без карточки.
    func testAutoDangerExecutesDangerousWithoutApproval() async throws {
        let deleteCall = ToolCallRequest(id: "1", name: "delete_file",
                                         argumentsJSON: #"{"path":"a.md"}"#)
        let provider = ScriptedProvider(steps: [[deleteCall]])
        let (viewModel, executed) = makeViewModel(provider: provider, mode: .autoDanger)

        viewModel.input = "удали файл"
        viewModel.send()
        try await waitForGeneration(viewModel)

        // delete_file не в списке tools стаба, но гейт пропустил его без
        // карточки — маршрутизация ушла в MCP-фолбэк (ERROR), карточек нет.
        XCTAssertTrue(viewModel.pendingToolApprovals.isEmpty)
        _ = executed()
    }

    /// Отмена генерации во время ожидания approve — deny, чат разлочен.
    func testCancelGenerationResolvesPendingApproval() async throws {
        let provider = ScriptedProvider(steps: [[writeCall]])
        let (viewModel, executed) = makeViewModel(provider: provider, mode: .ask)

        viewModel.input = "создай файл"
        viewModel.send()
        try await waitForApproval(viewModel)
        XCTAssertEqual(viewModel.pendingToolApprovals.count, 1)

        guard let chatID = viewModel.selectedChatID else { return XCTFail("нет чата") }
        viewModel.cancelGeneration(chatID: chatID)
        try await waitForGeneration(viewModel)

        XCTAssertTrue(executed().isEmpty)
        XCTAssertTrue(viewModel.pendingToolApprovals.isEmpty)
        XCTAssertEqual(viewModel.selectedChat?.isLoading, false)
    }

    /// MCP-вызов (write-уровень) в режиме «Спрашивать» тоже проходит гейт —
    /// закрывает BACKLOG п. 10.
    func testMCPCallGatedInAskMode() async throws {
        let mcpCall = ToolCallRequest(id: "1", name: "srv__doThing", argumentsJSON: "{}")
        let provider = ScriptedProvider(steps: [[mcpCall]])
        let (viewModel, _) = makeViewModel(provider: provider, mode: .ask)

        var mcpExecuted: [String] = []
        viewModel.mcpBridge = ChatViewModel.MCPBridge(
            tools: { _ in [ToolDefinition(name: "srv__doThing", description: "mcp",
                                          schema: ToolSchemas.empty)] },
            execute: { name, _ in mcpExecuted.append(name); return "ок" })
        if let id = viewModel.selectedChatID,
           let index = viewModel.chats.firstIndex(where: { $0.id == id }) {
            viewModel.chats[index].configuration.enabledMCPServerIDs = [UUID()]
        }

        viewModel.input = "сделай в джире"
        viewModel.send()
        try await waitForApproval(viewModel)

        XCTAssertEqual(viewModel.pendingToolApprovals.first?.toolName, "srv__doThing")
        viewModel.resolveToolApproval(id: viewModel.pendingToolApprovals[0].id,
                                      decision: .allowOnce)
        try await waitForGeneration(viewModel)
        XCTAssertEqual(mcpExecuted, ["srv__doThing"])
    }
}
