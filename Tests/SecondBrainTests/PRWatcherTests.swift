// PRWatcherTests.swift — отслеживание PR (задача 36) без сети: декод фикстур
// GitHub, чистый дифф (baseline / новый PR / закрытый PR), GitHubClient на
// инжектированном транспорте (заголовки, 304, rate limit), интеграция
// watcher → engine на скриптованном провайдере.

import XCTest
@testable import SecondBrain

final class PRWatchDiffTests: XCTestCase {
    private func pulls(_ fixture: String) throws -> [GitHubPullRequest] {
        try JSONDecoder().decode([GitHubPullRequest].self, from: TestFixtures.data(fixture))
    }

    func testFixtureDecoding() throws {
        let fetched = try pulls("github_pulls_baseline.json")
        XCTAssertEqual(fetched.map(\.number), [41, 42])
        XCTAssertEqual(fetched[0].title, "Добавить кэш эмбеддингов")
        XCTAssertEqual(fetched[0].user.login, "octocat")
        XCTAssertEqual(fetched[0].htmlURL, "https://github.com/octo/hello/pull/41")
        XCTAssertEqual(fetched[0].diffURL, "https://github.com/octo/hello/pull/41.diff")
    }

    func testFirstPollIsBaselineWithoutTriggers() throws {
        let outcome = PRWatchDiff.newPRs(fetched: try pulls("github_pulls_baseline.json"),
                                         lastSeen: nil)
        XCTAssertTrue(outcome.triggers.isEmpty,
                      "существующие PR при включении пайплайна не триггерят")
        XCTAssertEqual(outcome.lastSeen, [41, 42])
    }

    func testNewPRTriggersAndClosedLeavesState() throws {
        // Во втором опросе: #43 новый, #41 закрыт (исчез из открытых).
        let outcome = PRWatchDiff.newPRs(fetched: try pulls("github_pulls_new.json"),
                                         lastSeen: [41, 42])
        XCTAssertEqual(outcome.triggers.map(\.number), [43], "новый PR — единственный триггер")
        XCTAssertEqual(outcome.lastSeen, [42, 43],
                       "закрытый уходит из lastSeen (переоткрытие триггернёт снова)")
    }

    func testMultipleNewPRsTriggerInAscendingOrder() throws {
        let fetched = try pulls("github_pulls_new.json") + [
            GitHubPullRequest(number: 40, title: "старый по номеру, но не виденный",
                              user: .init(login: "x"),
                              htmlURL: "https://github.com/octo/hello/pull/40",
                              diffURL: "https://github.com/octo/hello/pull/40.diff"),
        ]
        let outcome = PRWatchDiff.newPRs(fetched: fetched, lastSeen: [42])
        XCTAssertEqual(outcome.triggers.map(\.number), [40, 43], "по возрастанию номера")
    }

    func testPayloadTextContainsAllFields() throws {
        let pr = try pulls("github_pulls_new.json")[0]
        let payload = pr.payloadText
        XCTAssertTrue(payload.contains("PR #43: Новый пайплайн code review"))
        XCTAssertTrue(payload.contains("Автор: octocat"))
        XCTAssertTrue(payload.contains("URL: https://github.com/octo/hello/pull/43"))
        XCTAssertTrue(payload.contains("diff: https://github.com/octo/hello/pull/43.diff"))
    }
}

final class GitHubClientTests: XCTestCase {
    /// Транспорт-заглушка: записывает запрос, отдаёт скриптованный ответ.
    private func makeClient(status: Int, body: Data = Data(),
                            headers: [String: String] = [:],
                            captured: @escaping (URLRequest) -> Void) -> GitHubClient {
        var client = GitHubClient()
        client.perform = { request in
            captured(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: headers)!
            return (body, http)
        }
        return client
    }

    func testRequestHeadersWithTokenAndETag() async throws {
        var captured: URLRequest?
        let client = makeClient(status: 200,
                                body: try TestFixtures.data("github_pulls_baseline.json"),
                                captured: { captured = $0 })
        _ = try await client.openPulls(owner: "octo", repo: "hello",
                                       etag: "\"e-1\"", token: "ghтест")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.github.com/repos/octo/hello/pulls?state=open")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"e-1\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ghтест")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"),
                       "application/vnd.github+json")
    }

    func testNoAuthHeaderWithoutToken() async throws {
        var captured: URLRequest?
        let client = makeClient(status: 200,
                                body: try TestFixtures.data("github_pulls_baseline.json"),
                                captured: { captured = $0 })
        _ = try await client.openPulls(owner: "octo", repo: "hello", etag: nil, token: nil)
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testNotModifiedIsSilence() async throws {
        let client = makeClient(status: 304, captured: { _ in })
        let response = try await client.openPulls(owner: "o", repo: "r",
                                                  etag: "\"e-1\"", token: nil)
        XCTAssertEqual(response, .notModified)
    }

    func testOKParsesETagAndRateLimit() async throws {
        let client = makeClient(status: 200,
                                body: try TestFixtures.data("github_pulls_baseline.json"),
                                headers: ["ETag": "\"e-2\"", "x-ratelimit-remaining": "57"],
                                captured: { _ in })
        let response = try await client.openPulls(owner: "o", repo: "r", etag: nil, token: nil)
        guard case .ok(let pulls, let etag, let remaining) = response else {
            return XCTFail("ожидали .ok")
        }
        XCTAssertEqual(pulls.map(\.number), [41, 42])
        XCTAssertEqual(etag, "\"e-2\"")
        XCTAssertEqual(remaining, 57)
    }

    func testRateLimitErrorIsExplained() async {
        let client = makeClient(status: 403, captured: { _ in })
        do {
            _ = try await client.openPulls(owner: "o", repo: "r", etag: nil, token: nil)
            XCTFail("ожидали ошибку")
        } catch {
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?
                .contains("rate limit") == true)
        }
    }
}

@MainActor
final class PRWatcherTests: XCTestCase {
    var tempDir: URL!
    var registry: ProviderRegistry!
    var chatVM: ChatViewModel!
    var store: PipelineStore!
    var engine: PipelineEngine!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = ProviderRegistry()
        registry.register(
            ProviderDescriptor(id: "mock", displayName: "Mock",
                               capabilities: [.chat], isLocal: true, defaultModel: "m-1"),
            chat: MockChatProvider(responses: ["Ревью готово"]))
        chatVM = ChatViewModel(router: FunctionRouter(registry: registry,
                                                      config: FunctionRoutingConfig()),
                               registry: registry,
                               fileURL: tempDir.appendingPathComponent("chats.json"))
        store = PipelineStore(pipelinesURL: tempDir.appendingPathComponent("pipelines.json"),
                              runsURL: tempDir.appendingPathComponent("pipeline-runs.json"))
        engine = PipelineEngine(store: store, chatViewModel: chatVM)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func addPRPipeline() -> PipelineConfig {
        var pipeline = PipelineConfig(name: "PR-ревью")
        pipeline.trigger = .prWatch(owner: "octo", repo: "hello", pollIntervalMin: 5)
        pipeline.agentMode = .single
        pipeline.inputTemplate = "Сделай ревью: {{trigger_payload}}"
        store.add(pipeline)
        return pipeline
    }

    /// Watcher со скриптованным транспортом: каждый опрос снимает следующий
    /// ответ из очереди; пустая очередь = «сеть упала».
    private func makeWatcher(responses: [GitHubClient.PullsResponse]) -> PRWatcher {
        var queue = responses
        var client = GitHubClient()
        client.perform = { request in
            guard !queue.isEmpty else { throw URLError(.notConnectedToInternet) }
            switch queue.removeFirst() {
            case .notModified:
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 304,
                                                httpVersion: nil, headerFields: nil)!)
            case .ok(let pulls, let etag, let remaining):
                var headers: [String: String] = [:]
                if let etag { headers["ETag"] = etag }
                if let remaining { headers["x-ratelimit-remaining"] = "\(remaining)" }
                let body = try JSONEncoder().encode(pulls)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                                              httpVersion: nil, headerFields: headers)!)
            }
        }
        return PRWatcher(store: store, engine: engine, client: client,
                         tokenProvider: { nil })
    }

    private func fixturePulls(_ name: String) throws -> [GitHubPullRequest] {
        try JSONDecoder().decode([GitHubPullRequest].self, from: TestFixtures.data(name))
    }

    func testBaselineThenNewPRTriggersRun() async throws {
        let pipeline = addPRPipeline()
        let watcher = makeWatcher(responses: [
            .ok(pulls: try fixturePulls("github_pulls_baseline.json"),
                etag: "\"e-1\"", rateLimitRemaining: 59),
            .ok(pulls: try fixturePulls("github_pulls_new.json"),
                etag: "\"e-2\"", rateLimitRemaining: 58),
        ])

        // Первый опрос — baseline: прогонов нет, состояние записано.
        await watcher.tick(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(store.prWatchState[pipeline.id]?.lastSeenPRNumbers, [41, 42])
        XCTAssertTrue(store.runs.isEmpty, "baseline не триггерит прогоны")
        XCTAssertEqual(watcher.runtimeByPipeline[pipeline.id]?.etag, "\"e-1\"")
        XCTAssertEqual(watcher.runtimeByPipeline[pipeline.id]?.rateLimitRemaining, 59)

        // Второй опрос (интервал прошёл): новый #43 → один прогон с payload.
        await watcher.tick(now: Date(timeIntervalSince1970: 301))
        XCTAssertEqual(store.runs.count, 1)
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(run.trigger, .prWatch)
        XCTAssertEqual(run.status, .ok)
        XCTAssertTrue(run.payloadSummary?.contains("PR #43") == true)
        XCTAssertEqual(store.prWatchState[pipeline.id]?.lastSeenPRNumbers, [42, 43])
        // Промпт прогона отрендерен из шаблона с payload.
        let chat = try XCTUnwrap(chatVM.chats.first { $0.id == run.destinationChatID })
        XCTAssertTrue(chat.messages.first?.content
            .hasPrefix("Сделай ревью: PR #43") == true)
    }

    func testPollIntervalRespected() async throws {
        let pipeline = addPRPipeline()
        let watcher = makeWatcher(responses: [
            .ok(pulls: [], etag: nil, rateLimitRemaining: nil),
            .ok(pulls: [], etag: nil, rateLimitRemaining: nil),
        ])
        await watcher.tick(now: Date(timeIntervalSince1970: 0))
        let polledAt = watcher.runtimeByPipeline[pipeline.id]?.lastPolledAt
        XCTAssertNotNil(polledAt)

        // Через минуту интервал (5 мин) ещё не прошёл — опроса нет.
        await watcher.tick(now: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(watcher.runtimeByPipeline[pipeline.id]?.lastPolledAt, polledAt,
                       "интервал 5 мин не истёк — GitHub не дёргаем")
    }

    func testNotModifiedIsSilent() async throws {
        let pipeline = addPRPipeline()
        store.prWatchState[pipeline.id] = PRWatchState(lastSeenPRNumbers: [41, 42])
        let watcher = makeWatcher(responses: [.notModified])

        await watcher.tick(now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(store.runs.isEmpty, "304 → тишина")
        XCTAssertEqual(store.prWatchState[pipeline.id]?.lastSeenPRNumbers, [41, 42],
                       "состояние не тронуто")
        XCTAssertNil(watcher.runtimeByPipeline[pipeline.id]?.lastError)
    }

    func testNetworkErrorSetsBadgeAndRetriesSilently() async throws {
        let pipeline = addPRPipeline()
        // Очередь пуста → транспорт кидает notConnectedToInternet.
        let watcher = makeWatcher(responses: [])

        await watcher.tick(now: Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(watcher.runtimeByPipeline[pipeline.id]?.lastError,
                        "ошибка сети — бейдж в UI, не крэш и не запись в историю")
        XCTAssertTrue(store.runs.isEmpty)
    }

    func testDisabledPipelineNotPolled() async throws {
        var pipeline = addPRPipeline()
        pipeline.enabled = false
        store.mutate(id: pipeline.id) { $0.enabled = false }
        let watcher = makeWatcher(responses: [
            .ok(pulls: [], etag: nil, rateLimitRemaining: nil),
        ])
        await watcher.tick(now: Date(timeIntervalSince1970: 0))
        XCTAssertNil(watcher.runtimeByPipeline[pipeline.id]?.lastPolledAt,
                     "выключенный пайплайн не опрашивается")
    }
}
