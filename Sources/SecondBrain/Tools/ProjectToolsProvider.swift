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
    private var cached: (path: String, registry: ToolRegistry, executor: ToolExecutor)?

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

    /// Корень выбранного репозитория; nil — путь не задан (для /help, задача 22).
    func currentRepoRoot() -> URL? {
        let path = settingsStore.settings.projectRepoPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Регистратор+исполнитель для текущего пути настроек; nil — путь не задан.
    func current() -> (registry: ToolRegistry, executor: ToolExecutor)? {
        let path = settingsStore.settings.projectRepoPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            cached = nil
            return nil
        }
        if let cached, cached.path == path {
            return (cached.registry, cached.executor)
        }
        let root = URL(fileURLWithPath: path)
        let registry = ToolRegistry.projectTools(repoRoot: root)
        let executor = ToolExecutor(registry: registry, repoRoot: root)
        cached = (path, registry, executor)
        return (registry, executor)
    }
}
