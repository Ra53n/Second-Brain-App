// SlashCommandTests.swift — тесты слэш-команды /help (задача 22).
//
// Слои: чистый разбор команд, сборка [PROJECT_DOCS] (загрузчик и бюджет),
// секция в ChatPromptBuilder, поведение ChatViewModel (/help с вопросом идёт
// в генерацию с доками и project-инструментами; /help без вопроса и незнакомая
// команда отвечаются локально без LLM; без репозитория — понятная ошибка).

import XCTest
@testable import SecondBrain

// MARK: - Разбор команд

final class SlashCommandParseTests: XCTestCase {

    func testHelpWithQuestion() {
        XCTAssertEqual(SlashCommand.parse("/help где хранятся чаты?"),
                       .help(question: "где хранятся чаты?"))
        XCTAssertEqual(SlashCommand.parse("  /help вопрос  "),
                       .help(question: "вопрос"))
        XCTAssertEqual(SlashCommand.parse("/HELP вопрос"),
                       .help(question: "вопрос"), "имя команды регистронезависимо")
    }

    func testBareHelpIsUsage() {
        XCTAssertEqual(SlashCommand.parse("/help"), .helpUsage)
        XCTAssertEqual(SlashCommand.parse("/help   "), .helpUsage)
    }

    func testUnknownCommand() {
        XCTAssertEqual(SlashCommand.parse("/hepl вопрос"), .unknown("/hepl"))
        XCTAssertEqual(SlashCommand.parse("/абракадабра"), .unknown("/абракадабра"))
    }

    func testPlainTextIsNotACommand() {
        XCTAssertNil(SlashCommand.parse("обычный вопрос"))
        XCTAssertNil(SlashCommand.parse("1/2 чашки сахара"))
        XCTAssertNil(SlashCommand.parse("/ 5 — не команда: после слэша не буква"))
        XCTAssertNil(SlashCommand.parse("/2plus2"))
        XCTAssertNil(SlashCommand.parse(""))
    }

    func testUsageTextMentionsCatalogAndUnknown() {
        let usage = SlashCommand.usageText()
        XCTAssertTrue(usage.contains("/help"))
        let unknown = SlashCommand.usageText(unknownCommand: "/hepl")
        XCTAssertTrue(unknown.contains("«/hepl»"))
        XCTAssertTrue(unknown.contains("/help"))
    }
}

// MARK: - Сборка блока документации

final class ProjectDocsContextTests: XCTestCase {

    func testReadmeFirstThenDocs() {
        let block = ProjectDocsContext.build(files: [
            ("README.md", "О проекте"),
            ("docs/ARCH.md", "Архитектура")
        ])
        let readmeIndex = block.range(of: "=== README.md ===")!.lowerBound
        let archIndex = block.range(of: "=== docs/ARCH.md ===")!.lowerBound
        XCTAssertLessThan(readmeIndex, archIndex)
        XCTAssertTrue(block.contains("О проекте"))
        XCTAssertTrue(block.contains("Архитектура"))
    }

    func testBudgetTruncatesWithMarker() {
        let long = String(repeating: "а", count: 1000)
        let block = ProjectDocsContext.build(files: [("README.md", long)], budget: 300)
        XCTAssertTrue(block.contains("обрезано"), block.suffix(100).description)
        XCTAssertLessThan(block.count, 450)
    }

    func testFilesBeyondBudgetAreListedAsSkipped() {
        let long = String(repeating: "б", count: 500)
        let block = ProjectDocsContext.build(files: [
            ("README.md", long),
            ("docs/SKIPPED.md", "не влезет")
        ], budget: 400)
        XCTAssertTrue(block.contains("docs/SKIPPED.md"), block)
        XCTAssertTrue(block.contains("не вошли в бюджет"), block)
        XCTAssertFalse(block.contains("не влезет"), "контент пропущенного файла не попадает")
    }

    func testEmptyFilesGiveEmptyBlock() {
        XCTAssertEqual(ProjectDocsContext.build(files: []), "")
    }
}

final class ProjectDocsLoaderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("projectdocs-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testLoadsReadmeCaseInsensitiveAndDocsSorted() throws {
        try "read me".write(to: root.appendingPathComponent("ReadMe.md"),
                            atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("docs/B.md"),
                      atomically: true, encoding: .utf8)
        try "a".write(to: root.appendingPathComponent("docs/A.md"),
                      atomically: true, encoding: .utf8)
        try "не md".write(to: root.appendingPathComponent("docs/note.txt"),
                          atomically: true, encoding: .utf8)

        let files = ProjectDocsLoader.loadFiles(repoRoot: root)
        XCTAssertEqual(files.map(\.name), ["ReadMe.md", "docs/A.md", "docs/B.md"])
    }

    func testMissingDocsIsFine() {
        let files = ProjectDocsLoader.loadFiles(repoRoot: root)
        XCTAssertTrue(files.isEmpty)
    }
}

// MARK: - Секция [PROJECT_DOCS] в промпте

final class ProjectDocsPromptTests: XCTestCase {

    func testSystemPromptContainsProjectDocsSection() {
        let prompt = ChatPromptBuilder.systemPrompt(projectDocs: "=== README.md ===\nтекст")
        XCTAssertTrue(prompt.contains("[PROJECT_DOCS]"))
        XCTAssertTrue(prompt.contains("=== README.md ==="))
        XCTAssertTrue(prompt.contains("read_file"), "директива подсказывает инструменты")
    }

    func testSystemPromptWithoutProjectDocsHasNoSection() {
        XCTAssertFalse(ChatPromptBuilder.systemPrompt().contains("[PROJECT_DOCS]"))
        XCTAssertFalse(ChatPromptBuilder.systemPrompt(projectDocs: "").contains("[PROJECT_DOCS]"))
    }
}

// MARK: - Поведение ChatViewModel

@MainActor
final class SlashHelpViewModelTests: XCTestCase {

    /// Tool-capable провайдер: один ответ текстом, записывает system-промпт и tools.
    private final class RecordingToolProvider: ChatProvider, ToolCapableChatProvider {
        private(set) var receivedSystemPrompts: [String] = []
        private(set) var receivedTools: [ToolDefinition] = []
        private(set) var streamCalls = 0

        func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
            ChatResult(text: "не используется", usage: nil)
        }

        func stream(_ messages: [ChatMessageDTO],
                    settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            streamCalls += 1
            if let system = messages.first, system.role == .system {
                receivedSystemPrompts.append(system.content)
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.text("ответ по докам"))
                continuation.finish()
            }
        }

        func sendWithTools(_ messages: [ToolAwareMessage],
                           settings: ChatSettings,
                           tools: [ToolDefinition],
                           forceText: Bool) async throws -> ToolLoopStep {
            receivedTools = tools
            if let system = messages.first, system.role == .system, let content = system.content {
                receivedSystemPrompts.append(content)
            }
            return ToolLoopStep(text: "ответ по докам", toolCalls: [], usage: nil)
        }
    }

    /// Провайдер БЕЗ поддержки инструментов — для graceful degradation.
    private final class StreamOnlyProvider: ChatProvider {
        private(set) var receivedSystemPrompts: [String] = []

        func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
            ChatResult(text: "не используется", usage: nil)
        }

        func stream(_ messages: [ChatMessageDTO],
                    settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            if let system = messages.first, system.role == .system {
                receivedSystemPrompts.append(system.content)
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.text("деградированный ответ"))
                continuation.finish()
            }
        }
    }

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("slashhelp-\(UUID().uuidString).json")
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
        // Финальный дренаж MainActor-тасков.
        for _ in 0..<20 { await Task.yield() }
    }

    func testHelpInjectsDocsAndProjectTools() async throws {
        let provider = RecordingToolProvider()
        let viewModel = makeViewModel(provider: provider)
        viewModel.projectDocsProvider = { _ in "=== README.md ===\nЭто проект." }
        viewModel.projectToolsBridge = ChatViewModel.ProjectToolsBridge(
            available: { true },
            tools: { [ToolDefinition(name: "git_status", description: "статус",
                                     schema: ToolSchemas.empty)] },
            execute: { _, _ in "ок" })
        // projectToolsEnabled НЕ включён: /help форсирует инструменты сам.

        viewModel.input = "/help где хранятся чаты?"
        viewModel.send()
        try await waitForGeneration(viewModel)

        XCTAssertEqual(viewModel.selectedChat?.messages.last?.content, "ответ по докам")
        XCTAssertTrue(provider.receivedSystemPrompts.first?.contains("[PROJECT_DOCS]") == true)
        XCTAssertTrue(provider.receivedSystemPrompts.first?.contains("Это проект.") == true)
        XCTAssertEqual(provider.receivedTools.map(\.name), ["git_status"])
        // Сообщение пользователя хранится как есть — с «/help».
        let userMessage = viewModel.selectedChat?.messages.dropLast().last
        XCTAssertEqual(userMessage?.content, "/help где хранятся чаты?")
    }

    func testBareHelpAnswersLocallyWithoutLLM() async throws {
        let provider = RecordingToolProvider()
        let viewModel = makeViewModel(provider: provider)

        viewModel.input = "/help"
        viewModel.send()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(viewModel.selectedChat?.isLoading, false)
        XCTAssertEqual(provider.streamCalls, 0, "LLM не вызывается")
        XCTAssertEqual(viewModel.selectedChat?.messages.count, 2)
        XCTAssertTrue(viewModel.selectedChat?.messages.last?.content
            .contains("Доступные команды") == true)
    }

    func testUnknownCommandAnswersLocally() async throws {
        let provider = RecordingToolProvider()
        let viewModel = makeViewModel(provider: provider)

        viewModel.input = "/абракадабра сделай что-то"
        viewModel.send()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(provider.streamCalls, 0)
        XCTAssertTrue(viewModel.selectedChat?.messages.last?.content
            .contains("Неизвестная команда «/абракадабра»") == true)
    }

    func testHelpWithoutRepositoryShowsError() async throws {
        let provider = RecordingToolProvider()
        let viewModel = makeViewModel(provider: provider)
        viewModel.projectDocsProvider = { _ in nil } // репозиторий не настроен

        viewModel.input = "/help вопрос"
        viewModel.send()
        try await waitForGeneration(viewModel)

        XCTAssertTrue(viewModel.selectedChat?.errorText?
            .contains("Репозиторий проекта не выбран") == true)
        // Пустая заглушка ассистента убрана, остался только вопрос.
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.role, .user)
    }

    /// Провайдер без function calling: /help не падает, а отвечает по докам.
    func testHelpDegradesGracefullyWithoutToolSupport() async throws {
        let provider = StreamOnlyProvider()
        let viewModel = makeViewModel(provider: provider)
        viewModel.projectDocsProvider = { _ in "=== README.md ===\nДоки." }
        viewModel.projectToolsBridge = ChatViewModel.ProjectToolsBridge(
            available: { true },
            tools: { [ToolDefinition(name: "git_status", description: "с",
                                     schema: ToolSchemas.empty)] },
            execute: { _, _ in "ок" })

        viewModel.input = "/help вопрос"
        viewModel.send()
        try await waitForGeneration(viewModel)

        XCTAssertNil(viewModel.selectedChat?.errorText)
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.content, "деградированный ответ")
        XCTAssertTrue(provider.receivedSystemPrompts.first?.contains("[PROJECT_DOCS]") == true)
    }

    /// /help при включённом RAG: ретрив пропускается (докблок вместо него).
    func testHelpSkipsRagRetrieval() async throws {
        let provider = RecordingToolProvider()
        let viewModel = makeViewModel(provider: provider)
        viewModel.projectDocsProvider = { _ in "доки" }
        var ragCalled = false
        viewModel.ragProvider = { _, _ in ragCalled = true; return nil }
        if let id = viewModel.selectedChatID,
           let index = viewModel.chats.firstIndex(where: { $0.id == id }) {
            viewModel.chats[index].configuration.ragEnabled = true
        }

        viewModel.input = "/help вопрос"
        viewModel.send()
        try await waitForGeneration(viewModel)

        XCTAssertFalse(ragCalled, "RAG-ретрив не должен вызываться на /help-ходе")
    }
}
