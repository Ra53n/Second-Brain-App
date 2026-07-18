// PRWatcher.swift — отслеживание новых PR на GitHub (задача 36).
//
// Только поллинг (webhooks — вне объёма): GET /repos/{owner}/{repo}/pulls
// с интервалом из конфига пайплайна (минимум 5 мин — без токена rate limit
// GitHub всего 60 req/ч). Слои:
//  - PRWatchDiff — чистый дифф «какие PR новые» (тестируется на фикстурах);
//  - GitHubClient (CodeReview/GitHubClient.swift, общий для 36/37) — тонкий
//    HTTP с инжектируемым транспортом, ETag/If-None-Match, Bearer-токен;
//  - PRWatcher — минутный цикл поверх них.
// Персистентно только lastSeenPRNumbers (PipelineStore.prWatchState): нельзя
// ре-триггерить уже обработанные PR после рестарта. ETag/remaining/lastError —
// in-memory: лишний полный GET после рестарта не страшен, а бейдж ошибки —
// атрибут текущей сессии. Токен — Keychain, запись «github-token» (KeyStore).

import AppKit
import Foundation

/// Чистый дифф списка открытых PR против «уже виденных».
enum PRWatchDiff {
    struct Outcome: Equatable {
        /// Новые PR по возрастанию номера — каждый триггерит прогон.
        var triggers: [GitHubPullRequest]
        /// Новое состояние: ровно текущие открытые PR (закрытые уходят —
        /// переоткрытие честно триггерит снова).
        var lastSeen: Set<Int>
    }

    /// lastSeen == nil — первый опрос: baseline без триггеров (существующие
    /// PR не считаются «новыми», иначе включение пайплайна зальёт чат).
    static func newPRs(fetched: [GitHubPullRequest], lastSeen: Set<Int>?) -> Outcome {
        let fetchedNumbers = Set(fetched.map(\.number))
        guard let lastSeen else {
            return Outcome(triggers: [], lastSeen: fetchedNumbers)
        }
        let triggers = fetched
            .filter { !lastSeen.contains($0.number) }
            .sorted { $0.number < $1.number }
        return Outcome(triggers: triggers, lastSeen: fetchedNumbers)
    }
}

/// Минутный цикл поллинга PR-пайплайнов.
@MainActor
final class PRWatcher: ObservableObject {
    /// Сессионное состояние опроса per pipeline — для бейджа в UI.
    struct Runtime: Equatable {
        var lastPolledAt: Date?
        var etag: String?
        var rateLimitRemaining: Int?
        /// Последняя ошибка сети/API; nil — всё хорошо. Ошибка не прерывает
        /// цикл — тихий ретрай на следующем подошедшем тике.
        var lastError: String?
    }

    @Published private(set) var runtimeByPipeline: [UUID: Runtime] = [:]

    private let store: PipelineStore
    private let engine: PipelineEngine
    private let client: GitHubClient
    /// Токен читается на каждый опрос (пользователь мог обновить в настройках).
    private let tokenProvider: () -> String?
    private var tickTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?

    init(store: PipelineStore, engine: PipelineEngine,
         client: GitHubClient = GitHubClient(),
         tokenProvider: @escaping () -> String? = { KeyStore.key(for: PRWatcher.githubTokenID) }) {
        self.store = store
        self.engine = engine
        self.client = client
        self.tokenProvider = tokenProvider
    }

    /// Запись Keychain для GitHub-токена (Настройки → «Инструменты»).
    nonisolated static let githubTokenID: ProviderID = "github-token"

    /// Идемпотентный старт минутного цикла (правило проекта: гасится на выходе).
    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(now: Date())
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Один тик: опрос каждого enabled PR-пайплайна, чей интервал подошёл.
    func tick(now: Date) async {
        for pipeline in store.pipelines {
            guard pipeline.enabled,
                  case .prWatch(let owner, let repo, let intervalMin) = pipeline.trigger,
                  !owner.isEmpty, !repo.isEmpty else { continue }
            let runtime = runtimeByPipeline[pipeline.id] ?? Runtime()
            if let last = runtime.lastPolledAt,
               now.timeIntervalSince(last) < Double(max(intervalMin,
                                                        PipelineTrigger.minPollIntervalMin)) * 60 {
                continue
            }
            await poll(pipeline: pipeline, owner: owner, repo: repo, now: now)
        }
    }

    /// Опрос одного репозитория: 304 → тишина; новые PR → прогоны по одному
    /// (последовательно — overlap guard движка пропустил бы пачку).
    private func poll(pipeline: PipelineConfig, owner: String, repo: String, now: Date) async {
        var runtime = runtimeByPipeline[pipeline.id] ?? Runtime()
        runtime.lastPolledAt = now
        do {
            let response = try await client.openPulls(owner: owner, repo: repo,
                                                      etag: runtime.etag,
                                                      token: tokenProvider())
            switch response {
            case .notModified:
                runtime.lastError = nil
            case .ok(let pulls, let etag, let remaining):
                runtime.etag = etag
                runtime.rateLimitRemaining = remaining
                runtime.lastError = nil
                let outcome = PRWatchDiff.newPRs(
                    fetched: pulls,
                    lastSeen: store.prWatchState[pipeline.id]?.lastSeenPRNumbers)
                store.prWatchState[pipeline.id] =
                    PRWatchState(lastSeenPRNumbers: outcome.lastSeen)
                store.persistNow()
                runtimeByPipeline[pipeline.id] = runtime
                for pr in outcome.triggers {
                    // Конфиг мог измениться, пока предыдущий PR обрабатывался.
                    guard let fresh = store.pipeline(id: pipeline.id), fresh.enabled else { break }
                    await engine.run(fresh, trigger: .prWatch, payload: pr.payloadText)
                }
                return
            }
        } catch {
            // Тихий ретрай следующим тиком; бейдж ошибки — в UI.
            runtime.lastError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        runtimeByPipeline[pipeline.id] = runtime
    }
}
