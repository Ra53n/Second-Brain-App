// RagIndexManager.swift — владелец RAG-индекса в рантайме (задача 13).
//
// Открывает rag.sqlite текущего vault, запускает синхронизацию (фоновым
// Task, отменяемо), публикует статус/прогресс для UI. Автообновление: FSEvents
// vault (diskChangeTick VaultManager) с debounce 2 с — но ТОЛЬКО когда индекс
// уже построен (первая индексация всегда явная кнопкой: эмбеддинги стоят
// денег/времени, молча жечь их нельзя). Смена модели эмбеддинга детектится
// тегом в БД → needsFullReindex, кнопка «Переиндексировать заново».

import Combine
import Foundation

@MainActor
final class RagIndexManager: ObservableObject {
    @Published private(set) var progress: RagIndexProgress?
    @Published private(set) var fileCount = 0
    @Published private(set) var chunkCount = 0
    @Published private(set) var updatedAt: Date?
    @Published private(set) var embeddingTag: String?
    @Published private(set) var needsFullReindex = false
    @Published var lastError: String?
    /// Ignore-список пользователя: относительные префиксы путей, по строке.
    @Published var ignoreList: String {
        didSet {
            guard ignoreList != oldValue else { return }
            UserDefaults.standard.set(ignoreList, forKey: Self.ignoreKey)
        }
    }

    static let ignoreKey = "rag.ignoreList"

    private let vaultManager: VaultManager
    private let router: FunctionRouter
    private var index: RagIndex?
    private var indexVaultID: String?
    private var syncTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    var isIndexing: Bool { progress != nil }

    init(vaultManager: VaultManager, router: FunctionRouter) {
        self.vaultManager = vaultManager
        self.router = router
        self.ignoreList = UserDefaults.standard.string(forKey: Self.ignoreKey) ?? ""

        // Смена vault → другой индекс.
        vaultManager.$vaultURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reopenIndex() }
            .store(in: &cancellables)
        // FSEvents: инкрементальный доиндекс изменённого — только если индекс
        // уже построен (см. шапку файла).
        vaultManager.$diskChangeTick
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.chunkCount > 0, !self.isIndexing else { return }
                self.reindex()
            }
            .store(in: &cancellables)
        reopenIndex()
    }

    /// Индекс текущего vault (для ретрива задачи 14). nil — vault не открыт.
    var currentIndex: RagIndex? { index }

    /// Ретрив для чата (задача 14). nil — RAG невозможен (нет индекса/vault,
    /// сменилась модель эмбеддинга): чат работает без контекста, UI индекса
    /// уже показывает предупреждение.
    func retrieveForChat(query: String,
                         history: [ChatMessage],
                         configuration: ChatConfiguration,
                         chatProvider: ResolvedChatProvider?) async -> RagRetrievalOutcome? {
        guard let index = ensureIndex(), chunkCount > 0 else { return nil }
        guard let (embedder, model, tag) = currentEmbeddingTag(),
              index.embeddingTag == tag else { return nil }
        let options = RagRetriever.Options(topK: configuration.ragTopK,
                                           minScore: configuration.ragMinScore,
                                           queryRewrite: configuration.ragQueryRewrite,
                                           rerank: configuration.ragRerankEnabled)
        return await RagRetriever.retrieve(index: index,
                                           embedder: embedder,
                                           model: model,
                                           query: query,
                                           history: history,
                                           options: options,
                                           chatProvider: chatProvider)
    }

    /// Тег текущей модели эмбеддинга роутера («model|dim»); nil — нет провайдера.
    /// Модель теперь реально уходит в embed-вызовы (задача 28). Компонент dim
    /// в теге — от дефолта провайдера: кастомная модель с другой размерностью
    /// честно даст пустой поиск (guard в RagRetriever.search), а инвалидацию
    /// покрывает компонент model.
    func currentEmbeddingTag() -> (embedder: EmbeddingProvider, model: String, tag: String)? {
        guard let resolved = router.resolveEmbeddingProvider(for: .embedding) else { return nil }
        return (resolved.provider, resolved.model,
                "\(resolved.model)|\(resolved.provider.dimension)")
    }

    // MARK: - Индексация

    /// Инкрементальная синхронизация (или полная при fullRebuild).
    func reindex(fullRebuild: Bool = false) {
        guard syncTask == nil else { return }
        guard let vaultURL = vaultManager.vaultURL, let index = ensureIndex() else {
            lastError = RagError.vaultUnavailable.errorDescription
            return
        }
        guard let (embedder, model, tag) = currentEmbeddingTag() else {
            lastError = RagError.noEmbeddingProvider.errorDescription
            return
        }
        lastError = nil
        needsFullReindex = false
        progress = RagIndexProgress()
        let ignore = ignorePrefixes

        syncTask = Task { [weak self] in
            do {
                if fullRebuild {
                    try index.clearAll()
                }
                // Прогресс-колбэк @Sendable: захватываем let-ссылку (weak var
                // в Sendable-замыкании — ошибка Swift 6); цикл короткоживущий.
                let manager = self
                let publish: @Sendable (RagIndexProgress) -> Void = { snapshot in
                    Task { @MainActor in manager?.progress = snapshot }
                }
                try await RagIndexer.sync(
                    vaultURL: vaultURL,
                    index: index,
                    embedder: embedder,
                    embeddingModel: model,
                    embeddingTag: tag,
                    ignore: ignore,
                    progress: publish)
            } catch let error as RagError {
                if case .embeddingModelChanged = error {
                    self?.needsFullReindex = true
                }
                self?.lastError = error.errorDescription
            } catch is CancellationError {
                // Отмена — не ошибка: готовые файлы уже в индексе.
            } catch {
                self?.lastError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self?.progress = nil
            self?.syncTask = nil
            self?.refreshStats()
        }
    }

    func cancelIndexing() {
        syncTask?.cancel()
    }

    // MARK: - Внутренности

    private var ignorePrefixes: [String] {
        ignoreList.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Открывает (или переоткрывает) индекс текущего vault.
    private func ensureIndex() -> RagIndex? {
        guard let vaultID = vaultManager.vaultID else { return nil }
        if let index, indexVaultID == vaultID { return index }
        index?.close()
        index = try? RagIndex(path: RagIndex.fileURL(vaultID: vaultID).path)
        indexVaultID = vaultID
        return index
    }

    private func reopenIndex() {
        cancelIndexing()
        index?.close()
        index = nil
        indexVaultID = nil
        _ = ensureIndex()
        refreshStats()
    }

    private func refreshStats() {
        guard let index else {
            (fileCount, chunkCount, updatedAt, embeddingTag) = (0, 0, nil, nil)
            return
        }
        let stats = (try? index.stats()) ?? (files: 0, chunks: 0)
        fileCount = stats.files
        chunkCount = stats.chunks
        updatedAt = index.updatedAt
        embeddingTag = index.embeddingTag
        // Детект смены модели без запуска индексации.
        if let existing = index.embeddingTag,
           let current = currentEmbeddingTag()?.tag,
           existing != current {
            needsFullReindex = true
        }
    }
}
