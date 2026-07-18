// ProjectToolsTests.swift — тесты встроенных инструментов проекта (задача 21).
//
// Слои:
//  - чистые: парсер веток, SafePath, ToolRegistry/ToolExecutor (стаб-тул);
//  - интеграционные: Git*Tool на реальных temp-репозиториях (паттерн
//    GitClientIntegrationTests из задачи 16);
//  - маршрутизация: ChatViewModel направляет builtin-вызовы в project-мост,
//    qualified-вызовы (с «__») — в MCP-мост.

import XCTest
@testable import SecondBrain

// MARK: - Чистые тесты: парсер веток

final class GitBranchParserTests: XCTestCase {

    func testParsesCurrentLocalAndRemote() {
        let out = """
        *\tmain\trefs/heads/main
         \tfeature/x\trefs/heads/feature/x
         \torigin/HEAD\trefs/remotes/origin/HEAD
         \torigin/main\trefs/remotes/origin/main
        """
        let branches = GitBranchParser.parse(out)
        XCTAssertEqual(branches.current, "main")
        XCTAssertEqual(branches.local, ["main", "feature/x"])
        // origin/HEAD — символическая ссылка, не ветка.
        XCTAssertEqual(branches.remote, ["origin/main"])
    }

    func testDetachedHeadHasNoCurrent() {
        let out = """
         \tmain\trefs/heads/main
        """
        let branches = GitBranchParser.parse(out)
        XCTAssertNil(branches.current)
        XCTAssertEqual(branches.local, ["main"])
    }

    func testEmptyOutput() {
        let branches = GitBranchParser.parse("")
        XCTAssertNil(branches.current)
        XCTAssertTrue(branches.local.isEmpty)
        XCTAssertTrue(branches.remote.isEmpty)
    }

    /// Локальная ветка со слэшем в имени не должна попадать в remote.
    func testLocalBranchWithSlashStaysLocal() {
        let out = " \tfeature/deep/name\trefs/heads/feature/deep/name"
        let branches = GitBranchParser.parse(out)
        XCTAssertEqual(branches.local, ["feature/deep/name"])
        XCTAssertTrue(branches.remote.isEmpty)
    }
}

// MARK: - Чистые тесты: SafePath

final class SafePathTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("safepath-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testNormalRelativePath() throws {
        try "x".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let url = SafePath.resolve("file.txt", under: root)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "file.txt")
    }

    func testDotDotEscapeRejected() {
        XCTAssertNil(SafePath.resolve("../outside.txt", under: root))
        XCTAssertNil(SafePath.resolve("a/../../outside.txt", under: root))
    }

    func testAbsoluteAndHomePathsRejected() {
        XCTAssertNil(SafePath.resolve("/etc/passwd", under: root))
        XCTAssertNil(SafePath.resolve("~/secret", under: root))
        XCTAssertNil(SafePath.resolve("", under: root))
    }

    /// «..» внутри корня допустимы, пока итог не выходит наружу.
    func testDotDotInsideRootAllowed() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(SafePath.resolve("sub/../file.txt", under: root))
    }

    /// Симлинк внутри корня, указывающий наружу, — побег, отклоняется.
    func testSymlinkEscapeRejected() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("safepath-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"),
                           atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside)
        XCTAssertNil(SafePath.resolve("link/secret.txt", under: root))
    }
}

// MARK: - Стаб-инструмент для тестов регистратора/исполнителя

private final class EchoTool: BuiltinTool {
    let name = "echo"
    let description = "Возвращает аргумент text."
    let parameters = ToolSchemas.object(["text": ToolSchemas.string("Текст.")],
                                        required: ["text"])

    func execute(_ ctx: ToolContext) async -> ToolResult {
        guard let text = ctx.input("text") else { return .error("нет аргумента text") }
        return .ok("echo: \(text)")
    }
}

// MARK: - ToolRegistry / ToolExecutor

final class ToolRegistryTests: XCTestCase {

    func testFindByNameAndDefinitions() {
        let registry = ToolRegistry(tools: [EchoTool()])
        XCTAssertNotNil(registry.findByName("echo"))
        XCTAssertNil(registry.findByName("unknown"))
        XCTAssertEqual(registry.names, ["echo"])
        let defs = registry.definitions()
        XCTAssertEqual(defs.count, 1)
        XCTAssertEqual(defs[0].name, "echo")
        XCTAssertEqual(defs[0].description, "Возвращает аргумент text.")
    }

    /// Инвариант маршрутизации: имена встроенных инструментов без «__»
    /// (qualified-имена MCP всегда содержат «__») и схемы — объекты (OpenAI).
    func testProjectToolNamesAndSchemasInvariants() {
        let registry = ToolRegistry.projectTools(repoRoot: FileManager.default.temporaryDirectory)
        let defs = registry.definitions()
        XCTAssertEqual(Set(defs.map(\.name)),
                       ["git_branches", "git_status", "git_log", "git_diff",
                        "list_files", "read_file",
                        "search_files", "write_file", "edit_file",
                        "delete_file", "run_command"])
        for def in defs {
            XCTAssertFalse(def.name.contains("__"),
                           "\(def.name): коллизия с qualified-именами MCP")
            XCTAssertEqual(def.schema["type"]?.stringValue, "object",
                           "\(def.name): схема аргументов должна быть объектом")
            XCTAssertFalse(def.description.isEmpty)
        }
    }
}

final class ToolExecutorTests: XCTestCase {

    private func makeExecutor() -> ToolExecutor {
        ToolExecutor(registry: ToolRegistry(tools: [EchoTool()]),
                     repoRoot: FileManager.default.temporaryDirectory)
    }

    func testExecutesRegisteredTool() async {
        let result = await makeExecutor().execute(name: "echo",
                                                  argumentsJSON: #"{"text":"привет"}"#)
        XCTAssertEqual(result, "echo: привет")
    }

    func testUnknownToolReturnsError() async {
        let result = await makeExecutor().execute(name: "nope", argumentsJSON: "{}")
        XCTAssertTrue(result.hasPrefix("ERROR:"), result)
    }

    func testBrokenArgumentsJSONReturnsError() async {
        let result = await makeExecutor().execute(name: "echo", argumentsJSON: "{не json")
        XCTAssertTrue(result.hasPrefix("ERROR:"), result)
    }

    func testEmptyArgumentsBecomeEmptyObject() async {
        // Пустая строка аргументов не роняет исполнение — инструмент сам
        // сообщает об отсутствии обязательного аргумента.
        let result = await makeExecutor().execute(name: "echo", argumentsJSON: "")
        XCTAssertTrue(result.hasPrefix("ERROR:"), result)
    }
}

// MARK: - Интеграционные тесты Git*Tool (реальный git CLI)

final class GitToolsIntegrationTests: XCTestCase {

    private var tempRoot: URL!
    private var repoRoot: URL!
    private var executor: ToolExecutor!

    override func setUp() async throws {
        try XCTSkipIf(GitClient.detectGitPath() == nil, "git не найден")
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("projecttools-tests-\(UUID().uuidString)")
        repoRoot = tempRoot.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

        let client = GitClient(repoURL: repoRoot)
        try await client.initRepository()
        try await client.configSet("user.name", "Test")
        try await client.configSet("user.email", "test@example.com")
        try await client.configSet("commit.gpgsign", "false")
        try "# Проект\nОписание.\n".write(to: repoRoot.appendingPathComponent("README.md"),
                                          atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repoRoot.appendingPathComponent("docs"),
                                                withIntermediateDirectories: true)
        try "Схема данных".write(to: repoRoot.appendingPathComponent("docs/DATA.md"),
                                 atomically: true, encoding: .utf8)
        _ = try await client.commitAll(message: "первый коммит")

        executor = ToolExecutor(registry: ToolRegistry.projectTools(repoRoot: repoRoot),
                                repoRoot: repoRoot)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    func testGitBranches() async {
        let result = await executor.execute(name: "git_branches", argumentsJSON: "{}")
        XCTAssertFalse(result.hasPrefix("ERROR:"), result)
        XCTAssertTrue(result.contains("Текущая ветка:"), result)
    }

    func testGitStatusCleanAndDirty() async throws {
        var result = await executor.execute(name: "git_status", argumentsJSON: "{}")
        XCTAssertTrue(result.contains("Рабочее дерево чистое."), result)

        try "изменение".write(to: repoRoot.appendingPathComponent("README.md"),
                              atomically: true, encoding: .utf8)
        result = await executor.execute(name: "git_status", argumentsJSON: "{}")
        XCTAssertTrue(result.contains("README.md"), result)
    }

    func testGitLogRespectsLimit() async throws {
        let client = GitClient(repoURL: repoRoot)
        try "v2".write(to: repoRoot.appendingPathComponent("README.md"),
                       atomically: true, encoding: .utf8)
        _ = try await client.commitAll(message: "второй коммит")

        let all = await executor.execute(name: "git_log", argumentsJSON: "{}")
        XCTAssertEqual(all.split(separator: "\n").count, 2, all)
        let limited = await executor.execute(name: "git_log", argumentsJSON: #"{"limit":1}"#)
        XCTAssertEqual(limited.split(separator: "\n").count, 1, limited)
        XCTAssertTrue(limited.contains("второй коммит"), limited)
    }

    func testListFilesTrackedAndFiltered() async {
        let all = await executor.execute(name: "list_files", argumentsJSON: "{}")
        XCTAssertTrue(all.contains("README.md"), all)
        XCTAssertTrue(all.contains("docs/DATA.md"), all)

        let filtered = await executor.execute(name: "list_files",
                                              argumentsJSON: #"{"path":"docs"}"#)
        XCTAssertTrue(filtered.contains("docs/DATA.md"), filtered)
        XCTAssertFalse(filtered.contains("README.md"), filtered)

        let escaped = await executor.execute(name: "list_files",
                                             argumentsJSON: #"{"path":"../"}"#)
        XCTAssertTrue(escaped.hasPrefix("ERROR:"), escaped)
    }

    /// Папка без git: list_files падает на обход ФС.
    func testListFilesFallsBackToFileSystem() async throws {
        let plain = tempRoot.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try "x".write(to: plain.appendingPathComponent("note.md"),
                      atomically: true, encoding: .utf8)
        let plainExecutor = ToolExecutor(registry: ToolRegistry.projectTools(repoRoot: plain),
                                         repoRoot: plain)
        let result = await plainExecutor.execute(name: "list_files", argumentsJSON: "{}")
        XCTAssertTrue(result.contains("note.md"), result)
    }

    func testReadFileHappyPath() async {
        let result = await executor.execute(name: "read_file",
                                            argumentsJSON: #"{"path":"README.md"}"#)
        XCTAssertTrue(result.contains("# Проект"), result)
    }

    func testReadFileCapsSize() async throws {
        let big = String(repeating: "а", count: 5000)
        try big.write(to: repoRoot.appendingPathComponent("big.txt"),
                      atomically: true, encoding: .utf8)
        let result = await executor.execute(
            name: "read_file",
            argumentsJSON: #"{"path":"big.txt","maxBytes":100}"#)
        XCTAssertTrue(result.contains("обрезан"), result)
        // 100 байт UTF-8 → 50 кириллических символов + пометка.
        XCTAssertLessThan(result.count, 200, result)
    }

    func testReadFileRejectsBinaryAndMissingAndEscape() async throws {
        try Data([0x00, 0x01, 0x02]).write(to: repoRoot.appendingPathComponent("bin.dat"))
        let binary = await executor.execute(name: "read_file",
                                            argumentsJSON: #"{"path":"bin.dat"}"#)
        XCTAssertTrue(binary.hasPrefix("ERROR:"), binary)

        let missing = await executor.execute(name: "read_file",
                                             argumentsJSON: #"{"path":"нет.md"}"#)
        XCTAssertTrue(missing.hasPrefix("ERROR:"), missing)

        let escape = await executor.execute(name: "read_file",
                                            argumentsJSON: #"{"path":"../../etc/passwd"}"#)
        XCTAssertTrue(escape.hasPrefix("ERROR:"), escape)

        let directory = await executor.execute(name: "read_file",
                                               argumentsJSON: #"{"path":"docs"}"#)
        XCTAssertTrue(directory.hasPrefix("ERROR:"), directory)
    }
}

// MARK: - Маршрутизация в ChatViewModel

@MainActor
final class ProjectToolsRoutingTests: XCTestCase {

    /// Провайдер, запрашивающий два вызова (builtin и MCP), потом отвечающий.
    private final class TwoCallProvider: ChatProvider, ToolCapableChatProvider {
        var receivedTools: [ToolDefinition] = []
        private var step = 0

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
            receivedTools = tools
            step += 1
            if step == 1 {
                return ToolLoopStep(text: nil, toolCalls: [
                    ToolCallRequest(id: "1", name: "git_status", argumentsJSON: "{}"),
                    ToolCallRequest(id: "2", name: "srv__tool", argumentsJSON: "{}")
                ], usage: ChatUsage(promptTokens: 10, completionTokens: 2, totalTokens: 12))
            }
            return ToolLoopStep(text: "готово", toolCalls: [],
                                usage: ChatUsage(promptTokens: 20, completionTokens: 5,
                                                 totalTokens: 25))
        }
    }

    func testBuiltinCallsRouteToProjectBridgeAndQualifiedToMCP() async throws {
        let registry = ProviderRegistry()
        let provider = TwoCallProvider()
        registry.register(ProviderDescriptor(id: "scripted", displayName: "Scripted",
                                             capabilities: [.chat], isLocal: true,
                                             defaultModel: "m"),
                          chat: provider)
        let router = FunctionRouter(registry: registry)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = ChatViewModel(router: router, registry: registry, fileURL: fileURL)

        var projectCalls: [String] = []
        var mcpCalls: [String] = []
        viewModel.projectToolsBridge = ChatViewModel.ProjectToolsBridge(
            available: { _ in true },
            tools: { _ in [ToolDefinition(name: "git_status", description: "статус",
                                          schema: ToolSchemas.empty)] },
            rootURL: { _ in FileManager.default.temporaryDirectory },
            execute: { _, name, _, _ in projectCalls.append(name); return "статус ок" })
        viewModel.mcpBridge = ChatViewModel.MCPBridge(
            tools: { _ in [ToolDefinition(name: "srv__tool", description: "mcp",
                                          schema: ToolSchemas.empty)] },
            execute: { name, _ in mcpCalls.append(name); return "mcp ок" })

        guard let chatID = viewModel.selectedChatID,
              let index = viewModel.chats.firstIndex(where: { $0.id == chatID }) else {
            return XCTFail("нет выбранного чата")
        }
        viewModel.chats[index].configuration.providerID = "scripted"
        viewModel.chats[index].configuration.projectToolsEnabled = true
        viewModel.chats[index].configuration.enabledMCPServerIDs = [UUID()]
        // Задача 39: MCP-вызов — write-уровень; «Авто» пропускает без approve
        // (в дефолтном «Спрашивать» тест ждал бы решения пользователя).
        viewModel.chats[index].configuration.permissionMode = .auto

        viewModel.input = "проверь статус"
        viewModel.send()
        // Ждём завершения генерации (isLoading → false).
        for _ in 0..<200 where viewModel.selectedChat?.isLoading == true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(projectCalls, ["git_status"])
        XCTAssertEqual(mcpCalls, ["srv__tool"])
        // Модель получила слитый список инструментов из обоих источников.
        XCTAssertEqual(Set(provider.receivedTools.map(\.name)), ["git_status", "srv__tool"])
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.content, "готово")
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.toolCalls?.count, 2)
        // Задача 29: usage tool-цикла больше не выбрасывается (сумма итераций).
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.metrics?.totalTokens, 37)
    }

    /// Только project-инструменты (без MCP-серверов) тоже запускают tool-цикл.
    func testProjectToolsAloneTriggerToolLoop() async throws {
        let registry = ProviderRegistry()
        let provider = TwoCallProvider()
        registry.register(ProviderDescriptor(id: "scripted", displayName: "Scripted",
                                             capabilities: [.chat], isLocal: true,
                                             defaultModel: "m"),
                          chat: provider)
        let router = FunctionRouter(registry: registry)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = ChatViewModel(router: router, registry: registry, fileURL: fileURL)

        viewModel.projectToolsBridge = ChatViewModel.ProjectToolsBridge(
            available: { _ in true },
            tools: { _ in [ToolDefinition(name: "git_status", description: "статус",
                                          schema: ToolSchemas.empty)] },
            rootURL: { _ in FileManager.default.temporaryDirectory },
            execute: { _, _, _, _ in "ок" })
        // mcpBridge отсутствует; вызов srv__tool получит ERROR, цикл продолжится.

        guard let chatID = viewModel.selectedChatID,
              let index = viewModel.chats.firstIndex(where: { $0.id == chatID }) else {
            return XCTFail("нет выбранного чата")
        }
        viewModel.chats[index].configuration.providerID = "scripted"
        viewModel.chats[index].configuration.projectToolsEnabled = true
        viewModel.chats[index].configuration.permissionMode = .auto

        viewModel.input = "статус?"
        viewModel.send()
        for _ in 0..<200 where viewModel.selectedChat?.isLoading == true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(viewModel.selectedChat?.messages.last?.content, "готово")
        let calls = viewModel.selectedChat?.messages.last?.toolCalls ?? []
        XCTAssertEqual(calls.count, 2)
        // Вызов в отсутствующий MCP-мост честно вернул ERROR модели.
        XCTAssertEqual(calls.first { $0.name == "srv__tool" }?.ok, false)
    }
}

// MARK: - Миграция конфигурации

final class ProjectToolsConfigMigrationTests: XCTestCase {

    /// Старый chats.json без projectToolsEnabled загружается с дефолтом false.
    func testChatConfigurationMigration() throws {
        let json = #"{"providerID":"openai","ragEnabled":true}"#
        let config = try JSONDecoder().decode(ChatConfiguration.self,
                                              from: Data(json.utf8))
        XCTAssertFalse(config.projectToolsEnabled)
        XCTAssertTrue(config.ragEnabled)
    }

    /// Round-trip: включённый флаг переживает сохранение/загрузку.
    func testChatConfigurationRoundTrip() throws {
        var config = ChatConfiguration()
        config.projectToolsEnabled = true
        let data = try JSONEncoder().encode(config)
        let loaded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        XCTAssertTrue(loaded.projectToolsEnabled)
    }

    /// Задачи 31→34: legacy-источник знаний мигрирует в множество id баз.
    func testKnowledgeSourceMigrationAndRoundTrip() throws {
        // Старый конфиг без поля → vault.
        let old = try JSONDecoder().decode(ChatConfiguration.self,
                                           from: Data(#"{"ragEnabled":true}"#.utf8))
        XCTAssertEqual(old.enabledKnowledgeBaseIDs, [KnowledgeBase.vaultID])

        // Незнакомое значение из будущего → vault, не падение.
        let future = try JSONDecoder().decode(
            ChatConfiguration.self,
            from: Data(#"{"knowledgeSource":"galaxy"}"#.utf8))
        XCTAssertEqual(future.enabledKnowledgeBaseIDs, [KnowledgeBase.vaultID])

        // Legacy-конфиг задачи 31 с источником «Проект».
        let legacyProject = try JSONDecoder().decode(
            ChatConfiguration.self,
            from: Data(#"{"knowledgeSource":"project"}"#.utf8))
        XCTAssertEqual(legacyProject.enabledKnowledgeBaseIDs, [KnowledgeBase.projectID])

        // Round-trip нового ключа; legacy-ключ больше не пишется.
        var config = ChatConfiguration()
        config.enabledKnowledgeBaseIDs = [KnowledgeBase.projectID, "folder-1"]
        config.ragAsTool = false
        let data = try JSONEncoder().encode(config)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("knowledgeSource"))
        let loaded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        XCTAssertEqual(loaded.enabledKnowledgeBaseIDs, [KnowledgeBase.projectID, "folder-1"])
        XCTAssertFalse(loaded.ragAsTool)

        // Новый ключ в приоритете над legacy, если встретились оба.
        let both = try JSONDecoder().decode(
            ChatConfiguration.self,
            from: Data(#"{"knowledgeSource":"project","enabledKnowledgeBaseIDs":["vault"]}"#.utf8))
        XCTAssertEqual(both.enabledKnowledgeBaseIDs, [KnowledgeBase.vaultID])
    }

    /// Шаблон git MCP-сервера: uvx mcp-server-git, выключен по умолчанию.
    func testGitTemplate() {
        let bare = MCPServer.gitTemplate()
        XCTAssertEqual(bare.command, "uvx")
        XCTAssertEqual(bare.args, ["mcp-server-git"])
        XCTAssertFalse(bare.enabled)

        let withPath = MCPServer.gitTemplate(repositoryPath: "/tmp/repo")
        XCTAssertEqual(withPath.args, ["mcp-server-git", "--repository", "/tmp/repo"])
    }

    /// Шаблон filesystem MCP-сервера (задача 39): npx server-filesystem,
    /// выключен по умолчанию.
    func testFilesystemTemplate() {
        let bare = MCPServer.filesystemTemplate()
        XCTAssertEqual(bare.command, "npx")
        XCTAssertEqual(bare.args, ["-y", "@modelcontextprotocol/server-filesystem"])
        XCTAssertFalse(bare.enabled)

        let withPath = MCPServer.filesystemTemplate(rootPath: "/tmp/repo")
        XCTAssertEqual(withPath.args,
                       ["-y", "@modelcontextprotocol/server-filesystem", "/tmp/repo"])
    }

    /// Задача 39: старый chats.json без новых полей грузится с дефолтами
    /// (глобальный каталог, режим «Спрашивать»), round-trip сохраняет их.
    func testTask39ConfigurationMigrationAndRoundTrip() throws {
        let old = try JSONDecoder().decode(ChatConfiguration.self,
                                           from: Data(#"{"ragEnabled":true}"#.utf8))
        XCTAssertNil(old.projectRootPath)
        XCTAssertEqual(old.permissionMode, .ask)

        var config = ChatConfiguration()
        config.projectRootPath = "/tmp/мой-проект"
        config.permissionMode = .autoDanger
        let data = try JSONEncoder().encode(config)
        let loaded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        XCTAssertEqual(loaded.projectRootPath, "/tmp/мой-проект")
        XCTAssertEqual(loaded.permissionMode, .autoDanger)
    }

    /// Задача 39: сообщение с fileChanges переживает encode/decode; старое
    /// сообщение без поля грузится с nil.
    func testFileChangesPersistenceRoundTrip() throws {
        var message = ChatMessage(role: .assistant, content: "готово")
        message.fileChanges = [FileChangeDisplay(relativePath: "a.md", kind: .created,
                                                 diff: "+строка")]
        let data = try JSONEncoder().encode(message)
        let loaded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(loaded.fileChanges?.count, 1)
        XCTAssertEqual(loaded.fileChanges?.first?.kind, .created)

        let old = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(#"{"role":"assistant","content":"x"}"#.utf8))
        XCTAssertNil(old.fileChanges)
    }
}

// MARK: - Per-root кэш провайдера (задача 39)

@MainActor
final class ProjectToolsProviderRootTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-root-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testEffectiveRootOverrideAndFallback() {
        let store = SettingsStore(fileURL: tempDir.appendingPathComponent("settings.json"))
        let provider = ProjectToolsProvider(settingsStore: store)

        // Ничего не задано → nil.
        XCTAssertNil(provider.effectiveRootURL(override: nil))
        XCTAssertNil(provider.toolset(rootOverride: "  "))

        // Глобальный путь — фолбэк; override чата — приоритет.
        store.settings.projectRepoPath = "/tmp/global"
        XCTAssertEqual(provider.effectiveRootURL(override: nil)?.path, "/tmp/global")
        XCTAssertEqual(provider.effectiveRootURL(override: "/tmp/chat")?.path, "/tmp/chat")
    }

    /// Два разных корня → два исполнителя; тот же корень → кэш.
    func testToolsetCachePerRoot() {
        let store = SettingsStore(fileURL: tempDir.appendingPathComponent("settings.json"))
        store.settings.projectRepoPath = tempDir.path
        let provider = ProjectToolsProvider(settingsStore: store)

        let global = provider.toolset(rootOverride: nil)
        let globalAgain = provider.toolset(rootOverride: nil)
        XCTAssertNotNil(global)
        XCTAssertTrue(global?.executor === globalAgain?.executor, "кэш по корню")

        let other = provider.toolset(rootOverride: tempDir.appendingPathComponent("x").path)
        XCTAssertNotNil(other)
        XCTAssertFalse(global?.executor === other?.executor, "разные корни — разные исполнители")
    }
}
