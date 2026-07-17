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
                    settings: ChatSettings) -> AsyncThrowingStream<String, Error> {
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
