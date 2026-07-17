// ProjectDocsRag.swift — RAG-индекс документации проекта (задача 25).
//
// Закрывает исходное требование «README + папка docs в RAG»: доки выбранного
// репозитория индексируются в отдельную БД project-docs.sqlite (переиспользуем
// RagIndex/MarkdownChunker/Vector задачи 13), /help ретривит top-K чанков
// вместо полного контекста. Фолбэк на полный контекст остаётся в
// ProjectToolsProvider — /help обязан работать и без ключа эмбеддингов.
//
// Синхронизация ленивая (при /help): доки меняются редко, FSEvents не нужен.

import Foundation

/// Actor-владелец индекса доков: сериализует доступ к RagIndex (он не
/// потокобезопасен) и кэширует открытую БД по пути репозитория.
actor ProjectDocsIndexService {
    /// Сколько чанков доков уходит в [PROJECT_DOCS] при ретриве.
    static let topK = 6

    private var cached: (path: String, index: RagIndex)?

    /// Путь БД индекса доков: рядом с индексами vault, ключ — id пути репо.
    nonisolated static func indexFileURL(repoRoot: URL) -> URL {
        Config.appSupportDirectory
            .appendingPathComponent(VaultID.make(for: repoRoot), isDirectory: true)
            .appendingPathComponent("project-docs.sqlite")
    }

    /// Блок [PROJECT_DOCS] через RAG: синхронизирует индекс с файлами доков и
    /// возвращает top-K релевантных чанков. nil — индексировать/искать нечего
    /// или произошла ошибка (вызывающий уходит в фолбэк полного контекста).
    func helpBlock(repoRoot: URL,
                   embedder: EmbeddingProvider,
                   tag: String,
                   question: String,
                   topK: Int = ProjectDocsIndexService.topK) async -> String? {
        do {
            let index = try openIndex(repoRoot: repoRoot)
            try await sync(index: index, repoRoot: repoRoot, embedder: embedder, tag: tag)
            return try await retrieve(index: index, embedder: embedder,
                                      question: question, topK: topK)
        } catch {
            // Ошибки индекса/эмбеддинга не роняют /help — фолбэк снаружи.
            return nil
        }
    }

    // MARK: - Внутренности

    private func openIndex(repoRoot: URL) throws -> RagIndex {
        let path = Self.indexFileURL(repoRoot: repoRoot).path
        if let cached, cached.path == path { return cached.index }
        let index = try RagIndex(path: path)
        cached = (path, index)
        return index
    }

    /// Инкрементальная синхронизация по mtime; смена модели эмбеддинга
    /// (тег «model|dim») → полная переиндексация: векторы несовместимы.
    private func sync(index: RagIndex, repoRoot: URL,
                      embedder: EmbeddingProvider, tag: String) async throws {
        if index.embeddingTag != tag {
            try index.clearAll()
            index.embeddingTag = tag
        }

        let files = ProjectDocsLoader.loadFiles(repoRoot: repoRoot)
        let indexed = try index.fileMtimes()
        var seen = Set<String>()

        for (name, content) in files {
            seen.insert(name)
            let mtime = Self.mtime(of: repoRoot.appendingPathComponent(name)) ?? 0
            if let existing = indexed[name], existing == mtime { continue }

            let chunks = MarkdownChunker.chunk(text: content, filePath: name)
            guard !chunks.isEmpty else {
                try index.replaceFile(path: name, mtime: mtime, chunks: [])
                continue
            }
            let vectors = try await embedder.embed(chunks.map(\.text))
                .map(Vector.normalize)
            try index.replaceFile(path: name, mtime: mtime,
                                  chunks: Array(zip(chunks, vectors)))
        }

        // Удалённые из репозитория доки убираем из индекса.
        for stale in indexed.keys where !seen.contains(stale) {
            try index.removeFile(path: stale)
        }
        index.updatedAt = Date()
    }

    /// Top-K чанков по вопросу → текст блока с источниками.
    private func retrieve(index: RagIndex, embedder: EmbeddingProvider,
                          question: String, topK: Int) async throws -> String? {
        let (chunks, vectors) = try index.loadAll()
        guard !chunks.isEmpty,
              let query = try await embedder.embed([question]).first else { return nil }
        let hits = Vector.topK(query: Vector.normalize(query), matrix: vectors, k: topK)
        guard !hits.isEmpty else { return nil }
        return Self.buildBlock(hits: hits.map { hit in
            let stored = chunks[hit.index]
            return (path: stored.chunk.filePath,
                    heading: stored.chunk.headingPath,
                    text: stored.chunk.text)
        })
    }

    /// Сборка блока из чанков: разделитель с источником (файл · заголовок).
    nonisolated static func buildBlock(
        hits: [(path: String, heading: String, text: String)]) -> String {
        hits.map { hit in
            let source = hit.heading.isEmpty ? hit.path : "\(hit.path) · \(hit.heading)"
            return "=== \(source) ===\n\(hit.text)"
        }
        .joined(separator: "\n\n")
    }

    private nonisolated static func mtime(of url: URL) -> TimeInterval? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
            .flatMap { ($0 as? Date)?.timeIntervalSince1970 }
    }
}
