// KnowledgeBaseManager.swift — единая точка ретрива по реестру баз (задача 34).
//
// Фасад над владельцами индексов: vault — RagIndexManager (FSEvents, детект
// смены эмбеддера — не трогаем), project — ProjectDocsIndexService через
// ProjectToolsProvider (ленивая синхронизация, /help не трогаем), папки —
// FolderIndexService. Отдаёт хиты единой валютой KnowledgeHit; исполняет
// rag_search (tool-режим) и статический фолбэк-ретрив (провайдер без tools).
//
// Спецслучай {vault}: ровно одна включённая база — vault — идёт старым
// пайплайном RagIndexManager.retrieveForChat (rewrite/rerank/порог), т.е.
// поведение существующих чатов с дефолтным конфигом не меняется вообще.

import Foundation

/// Итог исполнения rag_search: текст для модели + источники для цитат в UI.
struct RagToolOutcome {
    var text: String
    var sources: [RagSource]
}

@MainActor
final class KnowledgeBaseManager: ObservableObject {
    private let store: KnowledgeBaseStore
    private let ragIndexManager: RagIndexManager
    private let projectToolsProvider: ProjectToolsProvider
    private let router: FunctionRouter
    let folderService = FolderIndexService()

    init(store: KnowledgeBaseStore,
         ragIndexManager: RagIndexManager,
         projectToolsProvider: ProjectToolsProvider,
         router: FunctionRouter) {
        self.store = store
        self.ragIndexManager = ragIndexManager
        self.projectToolsProvider = projectToolsProvider
        self.router = router
    }

    /// Базы, доступные ходу чата: глобально включённые ∩ выбранные в чате.
    /// Порядок — как в реестре (vault, project, папки).
    func chatBases(enabledIDs: Set<String>) -> [KnowledgeBase] {
        store.enabledBases.filter { enabledIDs.contains($0.id) }
    }

    /// Определение rag_search для tool-use цикла; nil — искать негде.
    func toolDefinition(enabledIDs: Set<String>) -> ToolDefinition? {
        RagSearchTool.definition(bases: chatBases(enabledIDs: enabledIDs))
    }

    // MARK: - Исполнение rag_search (tool-режим)

    /// Вызов rag_search от модели: разбор аргументов → поиск по базе (или
    /// всем сразу) → форматированный текст + источники. Ошибки — текстом
    /// «ERROR: …» (конвенция ToolUseLoop: модель видит и реагирует). `secure:
    /// false` (задача 101) — режим сравнения baseline: без anti-injection
    /// оговорки в выдаче.
    func executeSearchTool(argumentsJSON: String,
                           enabledIDs: Set<String>,
                           topK: Int,
                           minScore: Double,
                           secure: Bool = true) async -> RagToolOutcome {
        let bases = chatBases(enabledIDs: enabledIDs)
        guard !bases.isEmpty else {
            return RagToolOutcome(
                text: "ERROR: в чате нет включённых баз знаний (чип «База» над полем ввода)",
                sources: [])
        }
        switch RagSearchTool.parseArguments(argumentsJSON, bases: bases) {
        case .failure(let message):
            return RagToolOutcome(text: "ERROR: \(message)", sources: [])
        case .success(let query, let baseID):
            let targets = baseID == nil ? bases : bases.filter { $0.id == baseID }
            var hitsPerBase: [[KnowledgeHit]] = []
            for base in targets {
                hitsPerBase.append(await hits(base: base, query: query,
                                              topK: topK, minScore: minScore))
            }
            let merged = KnowledgeMerge.dedupSorted(hitsPerBase: hitsPerBase,
                                                    topK: topK)
            let formatted = RagSearchTool.formatResult(hits: merged, secure: secure)
            return RagToolOutcome(text: formatted.text,
                                  sources: formatted.included.map(\.ragSource))
        }
    }

    // MARK: - Статический фолбэк (провайдер без tools / ragAsTool выключен)

    /// Ретрив для подстановки [RAG_CONTEXT]. nil — RAG невозможен (нет баз /
    /// нет эмбеддера): чат идёт без контекста, чип объясняет причину. `secure:
    /// false` (задача 101) — режим сравнения baseline: блок без anti-injection
    /// оговорки. Не действует на спецслучай {vault} — тот идёт старым
    /// пайплайном RagIndexManager без этого параметра (см. шапку).
    func retrieve(enabledIDs: Set<String>,
                  query: String,
                  history: [ChatMessage],
                  configuration: ChatConfiguration,
                  chatProvider: ResolvedChatProvider?,
                  secure: Bool = true) async -> RagRetrievalOutcome? {
        let bases = chatBases(enabledIDs: enabledIDs)
        guard !bases.isEmpty else { return nil }

        // Спецслучай {vault}: старый пайплайн со всеми опциями (см. шапку).
        if bases.count == 1, bases[0].id == KnowledgeBase.vaultID {
            return await ragIndexManager.retrieveForChat(query: query,
                                                         history: history,
                                                         configuration: configuration,
                                                         chatProvider: chatProvider)
        }

        guard router.resolveEmbeddingProvider(for: .embedding) != nil else { return nil }
        var hitsPerBase: [[KnowledgeHit]] = []
        for base in bases {
            hitsPerBase.append(await hits(base: base, query: query,
                                          topK: configuration.ragTopK,
                                          minScore: configuration.ragMinScore))
        }
        return KnowledgeMerge.merge(hitsPerBase: hitsPerBase,
                                    topK: configuration.ragTopK,
                                    secure: secure)
    }

    // MARK: - Хиты одной базы

    /// Top-K хитов базы под порогом minScore. Пустой массив при любой
    /// проблеме — RAG никогда не ломает отправку сообщения.
    func hits(base: KnowledgeBase, query: String,
              topK: Int, minScore: Double) async -> [KnowledgeHit] {
        let raw: [KnowledgeHit]
        switch base.kind {
        case .vault:
            raw = await vaultHits(base: base, query: query, topK: topK)
        case .project:
            raw = await projectToolsProvider.projectHits(question: query, topK: topK)
                .map { hit in
                    KnowledgeHit(baseID: base.id, baseName: base.name,
                                 filePath: hit.path, headingPath: hit.heading,
                                 text: hit.text, score: Double(hit.score))
                }
        case .folder:
            raw = await folderHits(base: base, query: query, topK: topK)
        }
        guard minScore > 0 else { return raw }
        return raw.filter { $0.score >= minScore }
    }

    private func vaultHits(base: KnowledgeBase, query: String,
                           topK: Int) async -> [KnowledgeHit] {
        guard let index = ragIndexManager.currentIndex,
              ragIndexManager.chunkCount > 0,
              let (embedder, model, tag) = ragIndexManager.currentEmbeddingTag(),
              index.embeddingTag == tag else { return [] }
        return await RagRetriever.search(index: index, embedder: embedder,
                                         model: model, query: query, topK: topK)
            .map { hit in
                KnowledgeHit(baseID: base.id, baseName: base.name,
                             filePath: hit.stored.chunk.filePath,
                             headingPath: hit.stored.chunk.headingPath,
                             text: hit.stored.chunk.text,
                             score: Double(hit.score))
            }
    }

    private func folderHits(base: KnowledgeBase, query: String,
                            topK: Int) async -> [KnowledgeHit] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let resolved = router.resolveEmbeddingProvider(for: .embedding)
        else { return [] }
        let tag = "\(resolved.model)|\(resolved.provider.dimension)"
        return await folderService.hits(root: URL(fileURLWithPath: base.path),
                                        embedder: resolved.provider,
                                        model: resolved.model,
                                        tag: tag,
                                        question: query,
                                        topK: topK)
            .map { hit in
                KnowledgeHit(baseID: base.id, baseName: base.name,
                             filePath: hit.path, headingPath: hit.heading,
                             text: hit.text, score: Double(hit.score))
            }
    }
}
