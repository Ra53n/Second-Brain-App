// ToolingUxTests.swift — тесты индикации туллинга (задача 27): состояние
// репозитория, сводки чипов, шаги мастера, роутер вкладок настроек,
// доступность провайдера чата, стабильность каталога встроенных инструментов.

import XCTest
@testable import SecondBrain

// MARK: - Состояние репозитория

final class ProjectRepoStateTests: XCTestCase {

    func testEmptyPathIsNotConfigured() {
        XCTAssertEqual(ProjectRepoState.evaluate(path: ""), .notConfigured)
        XCTAssertEqual(ProjectRepoState.evaluate(path: "   "), .notConfigured)
    }

    func testMissingFolderIsBroken() {
        let path = "/tmp/second-brain-нет-такой-папки-\(UUID().uuidString)"
        XCTAssertEqual(ProjectRepoState.evaluate(path: path), .broken(path: path))
    }

    func testExistingFolderIsReady() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("repostate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ProjectRepoState.evaluate(path: url.path), .ready(path: url.path))
    }
}

// MARK: - Сводки чипов

final class ToolSourceSummaryTests: XCTestCase {

    private func makeServer(name: String, enabled: Bool = true) -> MCPServer {
        var server = MCPServer()
        server.name = name
        server.enabled = enabled
        return server
    }

    private func status(for id: UUID, connected: Bool, toolCount: Int = 0,
                        error: String? = nil) -> MCPServerStatus {
        MCPServerStatus(serverID: id, connected: connected,
                        toolCount: toolCount, toolNames: [], error: error)
    }

    func testNothingEnabledGivesNoChips() {
        let summaries = ToolSourceSummary.make(configuration: ChatConfiguration(),
                                               projectRepo: .ready(path: "/tmp"),
                                               projectToolCount: 6,
                                               servers: [makeServer(name: "srv")],
                                               statuses: [:])
        XCTAssertTrue(summaries.isEmpty)
    }

    func testProjectChipStates() {
        var config = ChatConfiguration()
        config.projectToolsEnabled = true

        let ready = ToolSourceSummary.make(configuration: config,
                                           projectRepo: .ready(path: "/tmp/repo"),
                                           projectToolCount: 6, servers: [], statuses: [:])
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready[0].state, .ok)
        XCTAssertEqual(ready[0].count, 6)
        XCTAssertTrue(ready[0].detail.contains("/tmp/repo"))

        let missing = ToolSourceSummary.make(configuration: config,
                                             projectRepo: .notConfigured,
                                             projectToolCount: 6, servers: [], statuses: [:])
        XCTAssertEqual(missing[0].state, .warning)
        XCTAssertNil(missing[0].count)

        let broken = ToolSourceSummary.make(configuration: config,
                                            projectRepo: .broken(path: "/tmp/x"),
                                            projectToolCount: 6, servers: [], statuses: [:])
        XCTAssertEqual(broken[0].state, .warning)
        XCTAssertTrue(broken[0].detail.contains("/tmp/x"))
    }

    func testMCPChipStates() {
        let server = makeServer(name: "atlassian")
        var config = ChatConfiguration()
        config.enabledMCPServerIDs = [server.id]

        // Статуса нет → серый «не проверялся».
        let unknown = ToolSourceSummary.make(configuration: config,
                                             projectRepo: .notConfigured,
                                             projectToolCount: 6,
                                             servers: [server], statuses: [:])
        XCTAssertEqual(unknown.count, 1)
        XCTAssertEqual(unknown[0].state, .unknown)
        XCTAssertEqual(unknown[0].title, "atlassian")
        XCTAssertNil(unknown[0].count)

        // Подключён → зелёный с числом инструментов.
        let ok = ToolSourceSummary.make(configuration: config,
                                        projectRepo: .notConfigured,
                                        projectToolCount: 6,
                                        servers: [server],
                                        statuses: [server.id: status(for: server.id,
                                                                     connected: true,
                                                                     toolCount: 12)])
        XCTAssertEqual(ok[0].state, .ok)
        XCTAssertEqual(ok[0].count, 12)

        // Ошибка → оранжевый, текст ошибки в detail.
        let failed = ToolSourceSummary.make(configuration: config,
                                            projectRepo: .notConfigured,
                                            projectToolCount: 6,
                                            servers: [server],
                                            statuses: [server.id: status(for: server.id,
                                                                         connected: false,
                                                                         error: "boom")])
        XCTAssertEqual(failed[0].state, .warning)
        XCTAssertTrue(failed[0].detail.contains("boom"))
    }

    /// «Осиротевший» ID (сервер удалён) и глобально выключенный сервер чипов не дают.
    func testOrphanedAndDisabledServersGiveNoChips() {
        let disabled = makeServer(name: "off", enabled: false)
        var config = ChatConfiguration()
        config.enabledMCPServerIDs = [disabled.id, UUID()]

        let summaries = ToolSourceSummary.make(configuration: config,
                                               projectRepo: .notConfigured,
                                               projectToolCount: 6,
                                               servers: [disabled], statuses: [:])
        XCTAssertTrue(summaries.isEmpty)
    }

    /// Порядок: проект первым, затем серверы в порядке массива.
    func testOrderProjectFirstThenServers() {
        let a = makeServer(name: "a")
        let b = makeServer(name: "b")
        var config = ChatConfiguration()
        config.projectToolsEnabled = true
        config.enabledMCPServerIDs = [a.id, b.id]

        let summaries = ToolSourceSummary.make(configuration: config,
                                               projectRepo: .ready(path: "/tmp"),
                                               projectToolCount: 6,
                                               servers: [a, b], statuses: [:])
        XCTAssertEqual(summaries.map(\.title), ["Проект", "a", "b"])
        XCTAssertEqual(summaries[0].id, "project")
    }
}

// MARK: - Чип базы знаний (задача 28)

final class RagChipSummaryTests: XCTestCase {

    private func make(ragEnabled: Bool = true,
                      source: KnowledgeSource = .vault,
                      embedderAvailable: Bool = true,
                      chunkCount: Int = 100,
                      indexTag: String? = "m|8",
                      currentTag: String? = "m|8",
                      needsFullReindex: Bool = false,
                      isIndexing: Bool = false,
                      progressFraction: Double? = nil,
                      projectRepo: ProjectRepoState = .notConfigured,
                      docsChunks: Int? = nil) -> RagChipSummary? {
        RagChipSummary.make(ragEnabled: ragEnabled,
                            source: source,
                            embedderAvailable: embedderAvailable,
                            chunkCount: chunkCount,
                            indexTag: indexTag,
                            currentTag: currentTag,
                            needsFullReindex: needsFullReindex,
                            isIndexing: isIndexing,
                            progressFraction: progressFraction,
                            projectRepo: projectRepo,
                            docsChunks: docsChunks)
    }

    // MARK: Источник «Проект» (задача 31)

    func testProjectSourceStates() {
        // Репозиторий не выбран.
        let missing = make(source: .project)
        XCTAssertEqual(missing?.state, .repoMissing)
        XCTAssertEqual(missing?.health, .warning)

        // Репо есть, эмбеддера нет.
        XCTAssertEqual(make(source: .project, embedderAvailable: false,
                            projectRepo: .ready(path: "/tmp"))?.state, .noEmbedder)

        // Индекс доков ещё не строился — не ошибка (ленивая сборка).
        let lazyEmpty = make(source: .project, projectRepo: .ready(path: "/tmp"))
        XCTAssertEqual(lazyEmpty?.state, .empty)
        XCTAssertEqual(lazyEmpty?.health, .unknown)

        // Готов.
        let ready = make(source: .project, projectRepo: .ready(path: "/tmp"),
                         docsChunks: 42)
        XCTAssertEqual(ready?.state, .ready(chunks: 42))
        XCTAssertEqual(ready?.title, "База: Проект · 42")
    }

    func testVaultTitleCarriesSource() {
        XCTAssertEqual(make()?.title, "База: Vault · 100")
    }

    func testDisabledGivesNil() {
        XCTAssertNil(make(ragEnabled: false))
    }

    func testReadyState() {
        let chip = make()
        XCTAssertEqual(chip?.state, .ready(chunks: 100))
        XCTAssertEqual(chip?.health, .ok)
        XCTAssertEqual(chip?.title, "База: Vault · 100")
    }

    func testNoEmbedderState() {
        let chip = make(embedderAvailable: false)
        XCTAssertEqual(chip?.state, .noEmbedder)
        XCTAssertEqual(chip?.health, .warning)
        XCTAssertTrue(chip?.detail.contains("nomic-embed-text") == true)
    }

    func testEmptyIndexState() {
        XCTAssertEqual(make(chunkCount: 0, indexTag: nil)?.state, .empty)
    }

    func testTagMismatchNeedsReindex() {
        XCTAssertEqual(make(currentTag: "other|8")?.state, .needsReindex)
        XCTAssertEqual(make(needsFullReindex: true)?.state, .needsReindex)
    }

    /// Приоритеты: индексация поверх всего; нет эмбеддера поверх пустоты.
    func testStatePriorities() {
        XCTAssertEqual(make(embedderAvailable: false, chunkCount: 0,
                            isIndexing: true, progressFraction: 0.5)?.state,
                       .indexing(fraction: 0.5))
        XCTAssertEqual(make(embedderAvailable: false, chunkCount: 0)?.state, .noEmbedder)
    }
}

// MARK: - Мастер

final class ProjectWizardStateTests: XCTestCase {

    func testAllFalse() {
        let state = ProjectWizardState.make(repoConfigured: false,
                                            providerAvailable: false,
                                            toolsEnabledInChat: false)
        XCTAssertEqual(state.steps.map(\.kind), [.repo, .model, .tools])
        XCTAssertTrue(state.steps.allSatisfy { !$0.done })
        XCTAssertFalse(state.isComplete)
        XCTAssertFalse(state.repoDone)
    }

    func testEachFlagLightsItsStep() {
        XCTAssertTrue(ProjectWizardState.make(repoConfigured: true, providerAvailable: false,
                                              toolsEnabledInChat: false).repoDone)
        XCTAssertTrue(ProjectWizardState.make(repoConfigured: false, providerAvailable: true,
                                              toolsEnabledInChat: false)
            .steps.first { $0.kind == .model }?.done ?? false)
        XCTAssertTrue(ProjectWizardState.make(repoConfigured: false, providerAvailable: false,
                                              toolsEnabledInChat: true)
            .steps.first { $0.kind == .tools }?.done ?? false)
    }

    func testAllTrueIsComplete() {
        XCTAssertTrue(ProjectWizardState.make(repoConfigured: true, providerAvailable: true,
                                              toolsEnabledInChat: true).isComplete)
    }
}

// MARK: - Роутер вкладок настроек

@MainActor
final class SettingsTabRouterTests: XCTestCase {

    func testTabRawValuesStable() {
        // rawValue — контракт нотификации; менять нельзя без миграции.
        XCTAssertEqual(SettingsTab.allCases.map(\.rawValue),
                       ["general", "providers", "models", "meetings",
                        "localModels", "tools", "sync"])
        XCTAssertEqual(Notification.Name.openSettingsTab.rawValue,
                       "com.local.second-brain.openSettingsTab")
    }

    func testOpenSetsPendingAndPostsNotification() {
        var openedSettings = false
        let expectation = expectation(description: "нотификация с вкладкой")
        let observer = NotificationCenter.default.addObserver(
            forName: .openSettingsTab, object: nil, queue: .main) { note in
            if note.object as? SettingsTab == .tools { expectation.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        SettingsTabRouter.open(.tools, openSettings: { openedSettings = true })
        XCTAssertTrue(openedSettings)
        XCTAssertEqual(SettingsTabRouter.consumePending(), .tools)
        XCTAssertNil(SettingsTabRouter.consumePending(), "pending одноразовый")
        waitForExpectations(timeout: 1)
    }
}

// MARK: - Доступность провайдера чата

@MainActor
final class ChatProviderAvailabilityTests: XCTestCase {

    private final class StubProvider: ChatProvider {
        func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
            ChatResult(text: "ок", usage: nil)
        }

        func stream(_ messages: [ChatMessageDTO],
                    settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testAvailableWithRegisteredProvider() {
        let registry = ProviderRegistry()
        registry.register(ProviderDescriptor(id: "mock", displayName: "Mock",
                                             capabilities: [.chat], isLocal: true,
                                             defaultModel: "m"),
                          chat: StubProvider())
        let router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("avail-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = ChatViewModel(router: router, registry: registry, fileURL: fileURL)
        XCTAssertTrue(viewModel.chatProviderAvailable)
    }

    /// Задача 29: «Авто → DisplayName · model»; nil при явном провайдере.
    func testResolvedAutoDescription() {
        let registry = ProviderRegistry()
        registry.register(ProviderDescriptor(id: "mock", displayName: "Mock",
                                             capabilities: [.chat], isLocal: true,
                                             defaultModel: "m"),
                          chat: StubProvider())
        let router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = ChatViewModel(router: router, registry: registry, fileURL: fileURL)

        XCTAssertEqual(viewModel.resolvedAutoDescription, "Mock · m")

        viewModel.setModel(providerID: "mock", model: "m")
        XCTAssertNil(viewModel.resolvedAutoDescription, "явный провайдер — не «Авто»")
    }

    func testUnavailableWithEmptyRegistry() {
        let registry = ProviderRegistry()
        let router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("avail2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = ChatViewModel(router: router, registry: registry, fileURL: fileURL)
        XCTAssertFalse(viewModel.chatProviderAvailable)
    }
}

// MARK: - Пикер моделей (задача 32)

@MainActor
final class AvailableModelChoicesTests: XCTestCase {

    private final class StubChat: ChatProvider {
        func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
            ChatResult(text: "ок", usage: nil)
        }
        func stream(_ messages: [ChatMessageDTO],
                    settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testOnlyAvailableProvidersListedWithCuratedModels() async {
        let registry = ProviderRegistry()
        registry.register(ProviderDescriptor(id: "deepseek", displayName: "DeepSeek",
                                             capabilities: [.chat], isLocal: false,
                                             defaultModel: "deepseek-chat"),
                          chat: StubChat(), isAvailable: { true })
        registry.register(ProviderDescriptor(id: "openai", displayName: "OpenAI",
                                             capabilities: [.chat], isLocal: false,
                                             defaultModel: "gpt-4o-mini"),
                          chat: StubChat(), isAvailable: { false })
        let router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("choices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = ChatViewModel(router: router, registry: registry, fileURL: fileURL)

        let choices = await viewModel.availableModelChoices()
        XCTAssertEqual(choices.map(\.id), ["deepseek"], "недоступный OpenAI скрыт")
        XCTAssertEqual(choices.first?.models, ["deepseek-chat", "deepseek-reasoner"],
                       "кураторский список DeepSeek")
    }

    func testCuratedListsCoverRegisteredCloudProviders() {
        for id: ProviderID in ["openai", "gemini", "deepseek", "openrouter"] {
            XCTAssertFalse(ChatViewModel.curatedChatModels[id]?.isEmpty ?? true, id.rawValue)
        }
    }
}

// MARK: - Каталог встроенных инструментов

final class ProjectToolCatalogDisplayTests: XCTestCase {

    /// Каталог для вкладки настроек синхронизирован с реестром инструментов.
    func testProjectToolCatalogStable() {
        let catalog = ToolRegistry.projectToolCatalog()
        XCTAssertEqual(Set(catalog.map(\.name)),
                       ["git_branches", "git_status", "git_log", "git_diff",
                        "list_files", "read_file"])
        XCTAssertEqual(catalog.count, 6)
        for definition in catalog {
            XCTAssertFalse(definition.description.isEmpty, definition.name)
        }
    }
}
