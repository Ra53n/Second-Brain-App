// ProjectToolsProvider.swift — владелец инструментов проекта (задача 21).
//
// Связывает настройку projectRepoPath с рантаймом: лениво создаёт пару
// (ToolRegistry, ToolExecutor) для текущего пути и пересоздаёт её при смене
// пути в настройках (кэш по пути). Живёт в AppModel; чат обращается через
// замыкания ProjectToolsBridge (wireProjectTools в ContentView).

import Foundation

/// Лениво создаёт и кэширует исполнитель инструментов для выбранного репозитория.
@MainActor
final class ProjectToolsProvider {
    private let settingsStore: SettingsStore
    /// Роутер для эмбеддингов /help-ретрива (задача 25); nil — только фолбэк.
    private let router: FunctionRouter?
    /// RAG-индекс доков репозитория (задача 25).
    private let docsIndex = ProjectDocsIndexService()
    /// Кэш исполнителей по корню (задача 39): у каждого чата может быть свой
    /// каталог (projectRootPath), глобальный путь настроек — дефолт. Кэш не
    /// чистится: ключей столько, сколько разных корней открывал пользователь.
    private var cacheByRoot: [String: (registry: ToolRegistry, executor: ToolExecutor)] = [:]

    init(settingsStore: SettingsStore, router: FunctionRouter? = nil) {
        self.settingsStore = settingsStore
        self.router = router
    }

    /// Контекст /help по вопросу (задача 25): RAG-ретрив top-K чанков доков
    /// при доступном эмбеддере; фолбэк — полный текст доков под бюджет
    /// (обязан работать без единого ключа). nil — репозиторий не выбран.
    func helpContext(question: String) async -> String? {
        guard let root = currentRepoRoot() else { return nil }
        if let resolved = router?.resolveEmbeddingProvider(for: .embedding) {
            let tag = "\(resolved.model)|\(resolved.provider.dimension)"
            if let block = await docsIndex.helpBlock(repoRoot: root,
                                                    embedder: resolved.provider,
                                                    model: resolved.model,
                                                    tag: tag,
                                                    question: question) {
                return block
            }
        }
        return await Task.detached(priority: .userInitiated) {
            ProjectDocsContext.build(files: ProjectDocsLoader.loadFiles(repoRoot: root))
        }.value
    }

    /// RAG-ретрив по докам проекта для обычного хода чата с источником
    /// «Проект» (задача 31). nil — нет репозитория/эмбеддера или пусто:
    /// чат идёт без контекста, чип «База» объясняет причину.
    func projectRetrieval(question: String) async -> RagRetrievalOutcome? {
        guard let root = currentRepoRoot(),
              let resolved = router?.resolveEmbeddingProvider(for: .embedding) else { return nil }
        let tag = "\(resolved.model)|\(resolved.provider.dimension)"
        return await docsIndex.retrievalOutcome(repoRoot: root,
                                                embedder: resolved.provider,
                                                model: resolved.model,
                                                tag: tag,
                                                question: question)
    }

    /// Top-K хитов доков для реестра баз знаний (задача 34): сырые попадания
    /// без блока — KnowledgeBaseManager собирает выдачу единообразно для всех
    /// баз. Пустой массив — нет репозитория/эмбеддера или ошибка.
    func projectHits(question: String,
                     topK: Int) async -> [(path: String, heading: String,
                                           text: String, score: Float)] {
        guard let root = currentRepoRoot(),
              let resolved = router?.resolveEmbeddingProvider(for: .embedding) else { return [] }
        let tag = "\(resolved.model)|\(resolved.provider.dimension)"
        return await docsIndex.hits(repoRoot: root,
                                    embedder: resolved.provider,
                                    model: resolved.model,
                                    tag: tag,
                                    question: question,
                                    topK: topK)
    }

    /// Число чанков в индексе доков; nil — репозиторий не выбран/не строился.
    func docsChunkCount() async -> Int? {
        guard let root = currentRepoRoot() else { return nil }
        return await docsIndex.chunkCount(repoRoot: root)
    }

    /// Статистика индекса доков для вкладки «Инструменты» (задача 28);
    /// nil — репозиторий не выбран или индекс ещё не строился.
    func docsIndexStats() async -> ProjectDocsIndexService.DocsIndexStats? {
        guard let root = currentRepoRoot() else { return nil }
        return await docsIndex.stats(repoRoot: root)
    }

    /// Сброс индекса доков (перестроится при следующем /help).
    func resetDocsIndex() async {
        guard let root = currentRepoRoot() else { return }
        await docsIndex.reset(repoRoot: root)
    }

    /// Доступен ли провайдер эмбеддингов для ретрива/переиндексации доков
    /// (задача 47: определяет доступность кнопки «Перестроить индекс»).
    func hasEmbeddingProvider() -> Bool {
        router?.resolveEmbeddingProvider(for: .embedding) != nil
    }

    /// Полная переиндексация доков по кнопке «Перестроить индекс» (задача 47).
    /// Без репозитория/эмбеддера — no-op: кнопка в UI и так задизейблена.
    /// Ошибку синхронизации пробрасывает вызывающему для показа в UI (P6).
    func rebuildDocsIndex() async throws {
        guard let root = currentRepoRoot(),
              let resolved = router?.resolveEmbeddingProvider(for: .embedding) else { return }
        let tag = "\(resolved.model)|\(resolved.provider.dimension)"
        try await docsIndex.rebuild(repoRoot: root, embedder: resolved.provider,
                                    model: resolved.model, tag: tag)
    }

    /// Корень выбранного репозитория; nil — путь не задан (для /help, задача 22).
    func currentRepoRoot() -> URL? {
        effectiveRootURL(override: nil)
    }

    /// Эффективный корень: непустой override чата → он, иначе глобальный
    /// путь настроек; nil — не задан ни тот ни другой (задача 39).
    func effectiveRootURL(override: String?) -> URL? {
        let overridden = (override ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !overridden.isEmpty { return URL(fileURLWithPath: overridden) }
        let global = settingsStore.settings.projectRepoPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return global.isEmpty ? nil : URL(fileURLWithPath: global)
    }

    /// Регистратор+исполнитель для текущего пути настроек; nil — путь не задан.
    func current() -> (registry: ToolRegistry, executor: ToolExecutor)? {
        toolset(rootOverride: nil).map { ($0.registry, $0.executor) }
    }

    /// Регистратор+исполнитель для эффективного корня чата (задача 39):
    /// per-root кэш — два чата с разными каталогами получают два исполнителя.
    func toolset(rootOverride: String?) -> (registry: ToolRegistry,
                                            executor: ToolExecutor,
                                            root: URL)? {
        guard let root = effectiveRootURL(override: rootOverride) else { return nil }
        let key = root.standardizedFileURL.path
        if let cached = cacheByRoot[key] {
            return (cached.registry, cached.executor, root)
        }
        let registry = ToolRegistry.projectTools(repoRoot: root)
        let executor = ToolExecutor(registry: registry, repoRoot: root)
        cacheByRoot[key] = (registry, executor)
        return (registry, executor, root)
    }
}
