// CodeReviewTests.swift — задача 37: GitHub-клиент ревью (заголовки, декод,
// ошибки — на инжектированном транспорте), парсер PR-ссылок.
// Остальные слои (input/промпты/раннер/слэш) — в этом же файле по мере этапов.

import XCTest
@testable import SecondBrain

// MARK: - PRReference

final class PRReferenceTests: XCTestCase {
    func testFullURL() {
        XCTAssertEqual(PRReference.parse("https://github.com/octo/hello/pull/42"),
                       PRReference(owner: "octo", repo: "hello", number: 42))
    }

    func testURLWithTailAndQuery() {
        XCTAssertEqual(PRReference.parse("https://github.com/octo/hello/pull/42/files?diff=split#top"),
                       PRReference(owner: "octo", repo: "hello", number: 42))
        XCTAssertEqual(PRReference.parse("https://www.github.com/a-b/c.d/pull/7/commits"),
                       PRReference(owner: "a-b", repo: "c.d", number: 7))
    }

    func testShortForm() {
        XCTAssertEqual(PRReference.parse("octo/hello#42"),
                       PRReference(owner: "octo", repo: "hello", number: 42))
        XCTAssertEqual(PRReference.parse("  a_b/c-d#1  "),
                       PRReference(owner: "a_b", repo: "c-d", number: 1))
    }

    func testGarbageRejected() {
        XCTAssertNil(PRReference.parse(""))
        XCTAssertNil(PRReference.parse("привет мир"))
        XCTAssertNil(PRReference.parse("https://gitlab.com/o/r/pull/1"), "чужой хост")
        XCTAssertNil(PRReference.parse("https://github.com/octo/hello/issues/42"), "не pull")
        XCTAssertNil(PRReference.parse("https://github.com/octo/hello/pull/abc"), "номер не число")
        XCTAssertNil(PRReference.parse("octo/hello#0"), "номер должен быть положительным")
        XCTAssertNil(PRReference.parse("octo#42"), "нет repo")
        XCTAssertNil(PRReference.parse("a/b/c#42"), "лишний сегмент")
        XCTAssertNil(PRReference.parse("а вот 1/2#3"), "мусорная фраза с дробью")
    }

    func testFirstMatchInPayload() throws {
        let payload = """
        PR #43: Новый пайплайн code review
        Автор: octocat
        URL: https://github.com/octo/hello/pull/43
        diff: https://github.com/octo/hello/pull/43.diff
        """
        XCTAssertEqual(PRReference.firstMatch(in: payload),
                       PRReference(owner: "octo", repo: "hello", number: 43))
        XCTAssertNil(PRReference.firstMatch(in: "никаких ссылок тут нет"))
    }
}

// MARK: - CodeReviewInput (чистая сборка)

final class CodeReviewInputTests: XCTestCase {
    private func fixtureDiff() throws -> String {
        try TestFixtures.string("github_pr_diff.diff")
    }

    func testSplitByFileExtractsPaths() throws {
        let files = CodeReviewInput.splitByFile(try fixtureDiff())
        XCTAssertEqual(files.map(\.path),
                       ["Sources/App/StreamParser.swift",
                        "Sources/App/Session.swift",
                        "Tests/AppTests/StreamParserTests.swift"])
        XCTAssertTrue(files[0].text.hasPrefix("diff --git a/Sources/App/StreamParser.swift"))
        XCTAssertTrue(files[0].text.contains("guard !chunk.isEmpty"))
        XCTAssertFalse(files[0].text.contains("isAlive"), "секции файлов не смешиваются")
    }

    func testSplitByFileEmptyAndGarbage() {
        XCTAssertEqual(CodeReviewInput.splitByFile(""), [])
        XCTAssertEqual(CodeReviewInput.splitByFile("просто текст без заголовков"), [])
    }

    func testPackChunksSmallDiffSingleChunk() throws {
        let files = CodeReviewInput.splitByFile(try fixtureDiff())
        let chunks = CodeReviewInput.packChunks(files)
        XCTAssertEqual(chunks.count, 1, "малый diff — один чанк целиком")
        XCTAssertTrue(chunks[0].contains("StreamParser.swift"))
        XCTAssertTrue(chunks[0].contains("StreamParserTests.swift"))
    }

    func testPackChunksSplitsByLimitPreservingOrder() {
        let files = (0..<6).map { i in
            CodeReviewInput.FileDiff(path: "F\(i).swift",
                                     text: "diff --git F\(i)\n" + String(repeating: "x", count: 900))
        }
        let chunks = CodeReviewInput.packChunks(files, maxChars: 2_000)
        XCTAssertGreaterThan(chunks.count, 1)
        // Порядок файлов сохраняется сквозь чанки.
        let joined = chunks.joined(separator: "\n")
        let positions = (0..<6).compactMap { joined.range(of: "diff --git F\($0)")?.lowerBound }
        XCTAssertEqual(positions.count, 6)
        XCTAssertEqual(positions, positions.sorted())
    }

    func testOversizedFileIsCappedWithNote() {
        let huge = CodeReviewInput.FileDiff(
            path: "Generated.swift",
            text: String(repeating: "y", count: CodeReviewInput.maxFileChars + 5_000))
        let chunks = CodeReviewInput.packChunks([huge])
        XCTAssertTrue(chunks[0].contains("…(diff файла Generated.swift обрезан"),
                      "генерённая простыня режется с пометкой")
        XCTAssertLessThan(chunks[0].count, CodeReviewInput.maxFileChars + 200)
    }

    func testTestsSectionAffectedAndNeighbors() {
        let section = CodeReviewInput.testsSection(
            changedPaths: ["Sources/App/StreamParser.swift",
                           "Sources/App/Session.swift",
                           "Tests/AppTests/StreamParserTests.swift"],
            trackedFiles: ["Tests/AppTests/StreamParserTests.swift",
                           "Tests/AppTests/SessionTests.swift",
                           "Tests/AppTests/OtherTests.swift"])
        XCTAssertTrue(section.contains("- Tests/AppTests/StreamParserTests.swift"),
                      "изменённый тест — в затронутых")
        XCTAssertTrue(section.contains("- Tests/AppTests/SessionTests.swift"),
                      "сосед изменённого Session.swift найден")
        XCTAssertFalse(section.contains("OtherTests"), "чужие тесты не тянем")
        XCTAssertTrue(section.contains("read_file"))
    }

    func testTestsSectionEmptyHeuristics() {
        let section = CodeReviewInput.testsSection(changedPaths: ["README.md"],
                                                   trackedFiles: [])
        XCTAssertTrue(section.contains("не найдены"))
    }

    func testAssembleSectionOrderAndOptionality() {
        let full = CodeReviewInput.assemble(pr: "PR #1: тест", diff: "DIFF-TEXT",
                                            docs: "доки", tests: "тесты")
        let prPos = full.range(of: "[PR]")!.lowerBound
        let diffPos = full.range(of: "[DIFF]")!.lowerBound
        let docsPos = full.range(of: "[PROJECT_DOCS]")!.lowerBound
        let testsPos = full.range(of: "[TESTS]")!.lowerBound
        XCTAssertTrue(prPos < diffPos && diffPos < docsPos && docsPos < testsPos)

        let minimal = CodeReviewInput.assemble(pr: nil, diff: "D", docs: nil, tests: nil)
        XCTAssertFalse(minimal.contains("[PR]"))
        XCTAssertFalse(minimal.contains("[PROJECT_DOCS]"))
        XCTAssertTrue(minimal.contains("[DIFF]\nD"))
    }
}

// MARK: - CodeReviewPrompts (вердикт)

final class CodeReviewPromptsTests: XCTestCase {
    func testParseVerdictApproveAndNeedsWork() {
        XCTAssertEqual(CodeReviewPrompts.parseVerdict("…\nИТОГ РЕВЬЮ: APPROVE"), .approve)
        XCTAssertEqual(CodeReviewPrompts.parseVerdict("…\nитог ревью: нужны правки"),
                       .needsWork, "регистронезависимо")
    }

    func testParseVerdictMissingOrPartial() {
        XCTAssertNil(CodeReviewPrompts.parseVerdict("ревью без итога"))
        XCTAssertNil(CodeReviewPrompts.parseVerdict("ИТОГ РЕВЬЮ: непонятно что"))
    }

    func testParseVerdictLastMarkerWins() {
        let text = """
        Структура требует «ИТОГ РЕВЬЮ: APPROVE» последней строкой.
        …
        ИТОГ РЕВЬЮ: НУЖНЫ ПРАВКИ
        """
        XCTAssertEqual(CodeReviewPrompts.parseVerdict(text), .needsWork,
                       "процитированный маркер в начале не маскирует настоящий")
    }

    func testReviewTaskAvoidsFSMVerdictMarker() {
        let task = CodeReviewPrompts.reviewTask(assembledInput: "[DIFF]\nx")
        XCTAssertFalse(task.uppercased().contains("ВЕРДИКТ:"),
                       "маркер validation-фазы FSM не должен встречаться в задаче ревью")
        XCTAssertTrue(task.contains("ИТОГ РЕВЬЮ: APPROVE"))
        XCTAssertTrue(task.hasSuffix("[DIFF]\nx"))
    }
}

// MARK: - CodeReviewRunner (сборка + прогон + постинг)

@MainActor
final class CodeReviewRunnerTests: XCTestCase {
    var tempDir: URL!
    var registry: ProviderRegistry!
    var router: FunctionRouter!
    var chatVM: ChatViewModel!
    var settingsStore: SettingsStore!
    var toolsProvider: ProjectToolsProvider!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = ProviderRegistry()
        router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        settingsStore = SettingsStore(
            fileURL: tempDir.appendingPathComponent("settings.json"))
        settingsStore.settings.projectRepoPath = "" // без репо, если тест не задал
        toolsProvider = ProjectToolsProvider(settingsStore: settingsStore, router: router)
        chatVM = ChatViewModel(router: router, registry: registry,
                               fileURL: tempDir.appendingPathComponent("chats.json"))
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

    /// Ответы полного FSM-прогона: план → шаг → проверка → ответ-ревью.
    private var fsmReviewResponses: [String] {
        ["1. изучить diff",
         "изучено\nNEXT_STEP",
         "ВЕРДИКТ: ВЫПОЛНЕНО",
         "## Резюме изменений\nфикс\nИТОГ РЕВЬЮ: APPROVE"]
    }

    /// Клиент с фикстурами: метаданные PR #42 + diff; postComment пишет 201.
    private func makeClient(recordPosts: Recorder? = nil) -> GitHubClient {
        var client = GitHubClient()
        client.perform = { request in
            let url = request.url!.absoluteString
            if request.httpMethod == "POST" {
                recordPosts?.requests.append(request)
                return (try TestFixtures.data("github_comment_created.json"),
                        HTTPURLResponse(url: request.url!, statusCode: 201,
                                        httpVersion: nil, headerFields: nil)!)
            }
            let body: Data
            if request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.v3.diff" {
                body = try TestFixtures.data("github_pr_diff.diff")
            } else if url.hasSuffix("/pulls/42") {
                body = try TestFixtures.data("github_pr_42.json")
            } else {
                throw URLError(.unsupportedURL)
            }
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!)
        }
        return client
    }

    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private func makeRunner(client: GitHubClient? = nil,
                            token: String? = nil) -> CodeReviewRunner {
        CodeReviewRunner(chatViewModel: chatVM,
                         projectToolsProvider: toolsProvider,
                         router: router,
                         client: client ?? makeClient(),
                         tokenProvider: { token })
    }

    func testPrepareInputByReferenceAssemblesSections() async throws {
        register(MockChatProvider())
        let runner = makeRunner()
        let prepared = try await runner.prepareInput(
            reference: PRReference(owner: "octo", repo: "hello", number: 42))

        XCTAssertEqual(prepared.display, "Ревью PR #42: Fix: обрыв стриминга при пустом чанке")
        XCTAssertEqual(prepared.target, PRReference(owner: "octo", repo: "hello", number: 42))
        XCTAssertTrue(prepared.task.contains("[PR]\nPR #42:"))
        XCTAssertTrue(prepared.task.contains("[DIFF]\ndiff --git"),
                      "малый diff идёт целиком, без сжатия")
        XCTAssertTrue(prepared.task.contains("ИТОГ РЕВЬЮ: APPROVE"), "инструкция структуры")
        XCTAssertFalse(prepared.task.contains("[PROJECT_DOCS]"),
                       "репозиторий не настроен — доки опущены")
    }

    func testPrepareInputFromPRWatchPayloadSkipsMetadataRequest() async throws {
        let recorder = Recorder()
        var client = makeClient()
        let inner = client.perform
        client.perform = { request in
            recorder.requests.append(request)
            return try await inner(request)
        }
        let runner = makeRunner(client: client)
        let payload = """
        PR #42: Fix: обрыв стриминга при пустом чанке
        Автор: hubber
        URL: https://github.com/octo/hello/pull/42
        diff: https://github.com/octo/hello/pull/42.diff
        """
        let prepared = try await runner.prepareInput(prWatchPayload: payload)
        XCTAssertEqual(prepared.target?.number, 42)
        XCTAssertTrue(prepared.task.contains("[PR]\nPR #42:"))
        // Единственный сетевой вызов — diff (метаданные уже в payload).
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.value(forHTTPHeaderField: "Accept"),
                       "application/vnd.github.v3.diff")
    }

    func testPrepareInputPayloadWithoutPRThrows() async {
        let runner = makeRunner()
        do {
            _ = try await runner.prepareInput(prWatchPayload: "мусор без ссылок")
            XCTFail("ожидали payloadWithoutPR")
        } catch {
            XCTAssertEqual(error as? CodeReviewRunner.ReviewError, .payloadWithoutPR)
        }
    }

    func testPrepareLocalInputWithoutRepoThrows() async {
        let runner = makeRunner()
        do {
            _ = try await runner.prepareLocalInput()
            XCTFail("ожидали repositoryNotConfigured")
        } catch {
            XCTAssertEqual(error as? CodeReviewRunner.ReviewError, .repositoryNotConfigured)
        }
    }

    func testCondenseTriggersOnlyAboveThreshold() async throws {
        // Провайдер считает вызовы: конспект «SQUEEZED» на каждый чанк.
        let condenser = MockChatProvider(responses: ["SQUEEZED"])
        register(condenser)
        // Огромный diff: два файла по 20К — суммарно выше порога.
        let bigDiff = (0..<2).map { i in
            "diff --git a/F\(i).swift b/F\(i).swift\n"
                + String(repeating: "+x\n", count: 7_000)
        }.joined()
        var client = makeClient()
        client.perform = { request in
            if request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.v3.diff" {
                return (Data(bigDiff.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            }
            return (try TestFixtures.data("github_pr_42.json"),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        let runner = makeRunner(client: client)
        let prepared = try await runner.prepareInput(
            reference: PRReference(owner: "octo", repo: "hello", number: 42))
        XCTAssertTrue(prepared.task.contains("Сжатое изложение diff"))
        XCTAssertTrue(prepared.task.contains("SQUEEZED"))
        XCTAssertFalse(condenser.receivedMessages.isEmpty, "map-вызовы были")
        XCTAssertTrue(condenser.receivedMessages[0][0].content.contains("часть 1 из"),
                      "map-промпт по чанкам")
    }

    func testRunReviewMarksResultMessage() async throws {
        register(MockChatProvider(responses: fsmReviewResponses))
        let runner = makeRunner()
        let prepared = try await runner.prepareInput(
            reference: PRReference(owner: "octo", repo: "hello", number: 42))

        let status = await runner.runReview(prepared: prepared, chatIndex: 0)
        XCTAssertEqual(status, .finished)
        let last = chatVM.chats[0].messages.last
        XCTAssertEqual(last?.agentState, .answer)
        XCTAssertEqual(last?.reviewTarget,
                       PRReference(owner: "octo", repo: "hello", number: 42),
                       "итоговое сообщение маркировано для кнопки постинга")
        XCTAssertNil(last?.reviewPostedAt)
        XCTAssertEqual(CodeReviewPrompts.parseVerdict(last?.content ?? ""), .approve)
        // Видимое сообщение пользователя — короткое, а не полный input.
        XCTAssertEqual(chatVM.chats[0].messages.first?.content, prepared.display)
    }

    func testRunReviewFailedRunLeavesNoMarker() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "упало" } }
        let provider = MockChatProvider(responses: ["x"])
        provider.errorToThrow = Boom()
        register(provider)
        let runner = makeRunner()
        let prepared = try await runner.prepareInput(
            reference: PRReference(owner: "octo", repo: "hello", number: 42))

        let status = await runner.runReview(prepared: prepared, chatIndex: 0)
        XCTAssertEqual(status, .failed)
        XCTAssertFalse(chatVM.chats[0].messages.contains { $0.reviewTarget != nil },
                       "частичный результат failed-прогона не постится и не маркируется")
    }

    func testPostMarksMessagePosted() async throws {
        register(MockChatProvider(responses: fsmReviewResponses))
        let posts = Recorder()
        let runner = makeRunner(client: makeClient(recordPosts: posts), token: "write")
        let prepared = try await runner.prepareInput(
            reference: PRReference(owner: "octo", repo: "hello", number: 42))
        _ = await runner.runReview(prepared: prepared, chatIndex: 0)
        let messageID = try XCTUnwrap(chatVM.chats[0].messages.last?.id)

        try await runner.post(target: prepared.target!,
                              body: "текст ревью", messageID: messageID)
        XCTAssertEqual(posts.requests.count, 1)
        XCTAssertNotNil(chatVM.chats[0].messages.last?.reviewPostedAt,
                        "«Отправлено ✓» персистится на сообщении")
    }

    func testPostWithoutTokenFails() async throws {
        register(MockChatProvider(responses: fsmReviewResponses))
        let runner = makeRunner(token: nil)
        do {
            try await runner.post(target: PRReference(owner: "o", repo: "r", number: 1),
                                  body: "x", messageID: nil)
            XCTFail("ожидали .noToken")
        } catch {
            XCTAssertEqual(error as? GitHubClient.GitHubError, .noToken)
        }
    }
}

// MARK: - /review (парсинг и VM-путь)

final class ReviewSlashCommandParseTests: XCTestCase {
    func testReviewWithArgument() {
        XCTAssertEqual(SlashCommand.parse("/review https://github.com/o/r/pull/1"),
                       .review(argument: "https://github.com/o/r/pull/1"))
        XCTAssertEqual(SlashCommand.parse("/REVIEW o/r#5"), .review(argument: "o/r#5"))
        XCTAssertEqual(SlashCommand.parse("/review local"), .review(argument: "local"))
    }

    func testBareReviewHasEmptyArgument() {
        XCTAssertEqual(SlashCommand.parse("/review"), .review(argument: ""))
        XCTAssertEqual(SlashCommand.parse("/review   "), .review(argument: ""))
    }

    func testCatalogAndUsageMentionReview() {
        XCTAssertTrue(SlashCommand.catalog.contains { $0.name == "/review" })
        XCTAssertTrue(SlashCommand.usageText().contains("/review"))
        let usage = SlashCommand.reviewUsageText(problem: "Проблема.")
        XCTAssertTrue(usage.hasPrefix("Проблема."))
        XCTAssertTrue(usage.contains("owner/repo#N"))
        XCTAssertTrue(usage.contains("local"))
    }
}

@MainActor
final class ReviewSlashViewModelTests: XCTestCase {
    var tempDir: URL!
    var registry: ProviderRegistry!
    var router: FunctionRouter!
    var chatVM: ChatViewModel!
    var toolsProvider: ProjectToolsProvider!
    var runner: CodeReviewRunner!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = ProviderRegistry()
        router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        let settingsStore = SettingsStore(fileURL: tempDir.appendingPathComponent("settings.json"))
        settingsStore.settings.projectRepoPath = ""
        toolsProvider = ProjectToolsProvider(settingsStore: settingsStore, router: router)
        chatVM = ChatViewModel(router: router, registry: registry,
                               fileURL: tempDir.appendingPathComponent("chats.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Проводка раннера с фикстурным транспортом (метаданные+diff PR #42).
    private func wireRunner(failNetwork: Bool = false) {
        var client = GitHubClient()
        client.perform = { request in
            if failNetwork { throw URLError(.notConnectedToInternet) }
            let accept = request.value(forHTTPHeaderField: "Accept")
            let body: Data = accept == "application/vnd.github.v3.diff"
                ? try TestFixtures.data("github_pr_diff.diff")
                : try TestFixtures.data("github_pr_42.json")
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!)
        }
        runner = CodeReviewRunner(chatViewModel: chatVM,
                                  projectToolsProvider: toolsProvider,
                                  router: router,
                                  client: client,
                                  tokenProvider: { nil })
        chatVM.codeReviewRunner = runner
    }

    private func registerFSMProvider() {
        registry.register(
            ProviderDescriptor(id: "mock", displayName: "Mock",
                               capabilities: [.chat], isLocal: true, defaultModel: "m-1"),
            chat: MockChatProvider(responses: [
                "1. изучить diff",
                "изучено\nNEXT_STEP",
                "ВЕРДИКТ: ВЫПОЛНЕНО",
                "## Резюме\nok\nИТОГ РЕВЬЮ: APPROVE",
            ]))
    }

    /// Ждёт конца асинхронного пути /review (fetch → FSM → терминал).
    private func waitForReview(chatID: UUID, timeout: TimeInterval = 5) async {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            await Task.yield()
            let chat = chatVM.chats.first { $0.id == chatID }
            let busy = chat?.isLoading == true
                || chat?.agentContext?.status == .running
            if !busy, chat?.messages.isEmpty == false { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testValidURLStartsFSMReview() async throws {
        registerFSMProvider()
        wireRunner()
        let chatID = chatVM.selectedChatID!
        chatVM.input = "/review https://github.com/octo/hello/pull/42"
        chatVM.send()
        await waitForReview(chatID: chatID)

        let chat = chatVM.chats[0]
        XCTAssertEqual(chat.agentContext?.status, .finished, "FSM дошёл до терминала")
        XCTAssertEqual(chat.messages.first?.content,
                       "Ревью PR #42: Fix: обрыв стриминга при пустом чанке",
                       "видимое сообщение короткое")
        XCTAssertEqual(chat.messages.last?.reviewTarget?.number, 42)
        XCTAssertFalse(chat.isLoading)
    }

    func testBareReviewShowsUsageWithoutLLM() {
        registerFSMProvider()
        wireRunner()
        chatVM.input = "/review"
        chatVM.send()
        let chat = chatVM.chats[0]
        XCTAssertEqual(chat.messages.count, 2, "локальный обмен user+assistant")
        XCTAssertTrue(chat.messages.last!.content.contains("Использование: `/review"))
        XCTAssertNil(chat.agentContext, "прогон не стартовал")
        XCTAssertFalse(chat.isLoading)
    }

    func testGarbageArgumentShowsUsage() {
        registerFSMProvider()
        wireRunner()
        chatVM.input = "/review какой-то мусор"
        chatVM.send()
        XCTAssertTrue(chatVM.chats[0].messages.last!.content
            .contains("Не удалось разобрать"))
        XCTAssertFalse(chatVM.chats[0].isLoading)
    }

    func testLocalWithoutRepoShowsError() async {
        registerFSMProvider()
        wireRunner()
        let chatID = chatVM.selectedChatID!
        chatVM.input = "/review local"
        chatVM.send()
        await waitForReview(chatID: chatID)

        let chat = chatVM.chats[0]
        XCTAssertTrue(chat.messages.last!.content.contains("Репозиторий проекта не выбран"))
        XCTAssertNil(chat.agentContext)
        XCTAssertFalse(chat.isLoading, "ошибка обязана снять лок")
    }

    func testNetworkErrorReleasesLoadingLock() async {
        registerFSMProvider()
        wireRunner(failNetwork: true)
        let chatID = chatVM.selectedChatID!
        chatVM.input = "/review octo/hello#42"
        chatVM.send()
        await waitForReview(chatID: chatID)

        let chat = chatVM.chats[0]
        XCTAssertFalse(chat.isLoading, "сеть упала — чат не завис заблокированным")
        XCTAssertNil(chat.agentContext)
        XCTAssertEqual(chat.messages.count, 2, "ошибка показана локальным обменом")
    }
}

// MARK: - Пресет Code Review в PipelineEngine

@MainActor
final class CodeReviewPresetEngineTests: XCTestCase {
    var tempDir: URL!
    var registry: ProviderRegistry!
    var router: FunctionRouter!
    var chatVM: ChatViewModel!
    var store: PipelineStore!
    var engine: PipelineEngine!
    var runner: CodeReviewRunner!
    var postRecorder: Recorder!

    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = ProviderRegistry()
        registry.register(
            ProviderDescriptor(id: "mock", displayName: "Mock",
                               capabilities: [.chat], isLocal: true, defaultModel: "m-1"),
            chat: MockChatProvider(responses: [
                "1. изучить diff",
                "изучено\nNEXT_STEP",
                "ВЕРДИКТ: ВЫПОЛНЕНО",
                "## Резюме\nok\nИТОГ РЕВЬЮ: APPROVE",
            ]))
        router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        let settingsStore = SettingsStore(fileURL: tempDir.appendingPathComponent("settings.json"))
        settingsStore.settings.projectRepoPath = ""
        let toolsProvider = ProjectToolsProvider(settingsStore: settingsStore, router: router)
        chatVM = ChatViewModel(router: router, registry: registry,
                               fileURL: tempDir.appendingPathComponent("chats.json"))
        store = PipelineStore(pipelinesURL: tempDir.appendingPathComponent("pipelines.json"),
                              runsURL: tempDir.appendingPathComponent("pipeline-runs.json"))
        engine = PipelineEngine(store: store, chatViewModel: chatVM)

        postRecorder = Recorder()
        var client = GitHubClient()
        let posts = postRecorder!
        client.perform = { request in
            if request.httpMethod == "POST" {
                posts.requests.append(request)
                return (try TestFixtures.data("github_comment_created.json"),
                        HTTPURLResponse(url: request.url!, statusCode: 201,
                                        httpVersion: nil, headerFields: nil)!)
            }
            let body: Data = request.value(forHTTPHeaderField: "Accept")
                == "application/vnd.github.v3.diff"
                ? try TestFixtures.data("github_pr_diff.diff")
                : try TestFixtures.data("github_pr_42.json")
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!)
        }
        runner = CodeReviewRunner(chatViewModel: chatVM,
                                  projectToolsProvider: toolsProvider,
                                  router: router,
                                  client: client,
                                  tokenProvider: { "write-token" })
        engine.reviewRunner = runner
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var payload42: String {
        """
        PR #42: Fix: обрыв стриминга при пустом чанке
        Автор: hubber
        URL: https://github.com/octo/hello/pull/42
        diff: https://github.com/octo/hello/pull/42.diff
        """
    }

    func testPresetRunBuildsInputViaRunnerAndMarksMessage() async throws {
        let preset = PipelineConfig.codeReviewPreset()
        store.add(preset)

        let run = await engine.run(preset, trigger: .prWatch, payload: payload42)

        XCTAssertEqual(run.status, .ok)
        let chat = try XCTUnwrap(chatVM.chats.first { $0.id == run.destinationChatID })
        XCTAssertEqual(chat.messages.first?.content,
                       "Ревью PR #42: PR #42: Fix: обрыв стриминга при пустом чанке",
                       "display из payload, а не сырой inputTemplate")
        XCTAssertTrue(chat.agentContext?.task.contains("[DIFF]\ndiff --git") == true,
                      "input собран раннером (diff внутри)")
        XCTAssertEqual(chat.messages.last?.reviewTarget?.number, 42)
        XCTAssertTrue(postRecorder.requests.isEmpty, "автопост выключен по умолчанию")
    }

    func testPresetAutoPostAfterFinishedRun() async throws {
        var preset = PipelineConfig.codeReviewPreset()
        preset.autoPostReviewComment = true
        store.add(preset)

        let run = await engine.run(preset, trigger: .prWatch, payload: payload42)

        XCTAssertEqual(run.status, .ok)
        XCTAssertNil(run.errorText)
        XCTAssertEqual(postRecorder.requests.count, 1, "автопост после успешного терминала")
        XCTAssertEqual(postRecorder.requests.first?.url?.absoluteString,
                       "https://api.github.com/repos/octo/hello/issues/42/comments")
        let chat = try XCTUnwrap(chatVM.chats.first { $0.id == run.destinationChatID })
        XCTAssertNotNil(chat.messages.last?.reviewPostedAt)
    }

    func testPresetManualRunWithoutPayloadIsError() async throws {
        let preset = PipelineConfig.codeReviewPreset()
        store.add(preset)
        let run = await engine.run(preset, trigger: .manual)
        XCTAssertEqual(run.status, .error)
        XCTAssertTrue(run.errorText?.contains("PR-watch") == true)
        XCTAssertTrue(postRecorder.requests.isEmpty)
    }

    func testPresetPrepareFailureFinalizesAsErrorWithoutPost() async throws {
        var preset = PipelineConfig.codeReviewPreset()
        preset.autoPostReviewComment = true
        store.add(preset)
        // Payload без ссылки — подготовка падает до прогона.
        let run = await engine.run(preset, trigger: .prWatch, payload: "мусор")
        XCTAssertEqual(run.status, .error)
        XCTAssertTrue(postRecorder.requests.isEmpty,
                      "failed-прогон никогда не постится")
    }
}

// MARK: - GitHubClient (задача 37: pullRequest / diff / postComment)

final class GitHubClientReviewTests: XCTestCase {
    /// Транспорт-заглушка: записывает запросы, отдаёт скриптованный ответ.
    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private func makeClient(status: Int, body: Data = Data(),
                            recorder: Recorder) -> GitHubClient {
        var client = GitHubClient()
        client.perform = { request in
            recorder.requests.append(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
            return (body, http)
        }
        return client
    }

    func testPullRequestDecodesFixture() async throws {
        let recorder = Recorder()
        let client = makeClient(status: 200,
                                body: try TestFixtures.data("github_pr_42.json"),
                                recorder: recorder)
        let pr = try await client.pullRequest(owner: "octo", repo: "hello",
                                              number: 42, token: nil)
        XCTAssertEqual(pr.number, 42)
        XCTAssertEqual(pr.title, "Fix: обрыв стриминга при пустом чанке")
        XCTAssertEqual(pr.user.login, "hubber")
        XCTAssertEqual(pr.diffURL, "https://github.com/octo/hello/pull/42.diff")
        XCTAssertEqual(recorder.requests.first?.url?.absoluteString,
                       "https://api.github.com/repos/octo/hello/pulls/42")
    }

    func testDiffSendsAcceptHeaderAndReturnsText() async throws {
        let recorder = Recorder()
        let fixture = try TestFixtures.string("github_pr_diff.diff")
        let client = makeClient(status: 200, body: Data(fixture.utf8), recorder: recorder)

        let diff = try await client.diff(owner: "octo", repo: "hello",
                                         number: 42, token: "т")
        XCTAssertEqual(diff, fixture)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"),
                       "application/vnd.github.v3.diff")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer т")
    }

    func testDiffByDirectURL() async throws {
        let recorder = Recorder()
        let client = makeClient(status: 200, body: Data("diff --git…".utf8),
                                recorder: recorder)
        _ = try await client.diff(url: URL(string: "https://github.com/octo/hello/pull/42.diff")!,
                                  token: nil)
        XCTAssertEqual(recorder.requests.first?.url?.absoluteString,
                       "https://github.com/octo/hello/pull/42.diff",
                       "diff_url из payload PR-watch используется как есть")
    }

    func testPostCommentSendsBodyAndMethod() async throws {
        let recorder = Recorder()
        let client = makeClient(status: 201,
                                body: try TestFixtures.data("github_comment_created.json"),
                                recorder: recorder)
        try await client.postComment(owner: "octo", repo: "hello", number: 42,
                                     body: "## Резюме\nтекст", token: "write-token")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.github.com/repos/octo/hello/issues/42/comments")
        let payload = try JSONDecoder().decode([String: String].self,
                                               from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(payload["body"], "## Резюме\nтекст")
    }

    func testPostCommentWithoutTokenFailsBeforeNetwork() async {
        let recorder = Recorder()
        let client = makeClient(status: 201, recorder: recorder)
        do {
            try await client.postComment(owner: "o", repo: "r", number: 1,
                                         body: "x", token: nil)
            XCTFail("ожидали .noToken")
        } catch {
            XCTAssertEqual(error as? GitHubClient.GitHubError, .noToken)
            XCTAssertTrue(recorder.requests.isEmpty, "сетевой вызов не делался")
        }
    }

    func testErrorTextsAreHuman() async throws {
        for (code, fragment) in [(404, "не найден"), (401, "недействителен"),
                                 (403, "rate limit")] {
            let client = makeClient(status: code, recorder: Recorder())
            do {
                _ = try await client.pullRequest(owner: "o", repo: "r", number: 1, token: nil)
                XCTFail("ожидали ошибку \(code)")
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? ""
                XCTAssertTrue(text.contains(fragment), "код \(code): «\(text)»")
            }
        }
    }
}
