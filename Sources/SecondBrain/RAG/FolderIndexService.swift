// FolderIndexService.swift — индексы папочных баз знаний (задача 34).
//
// Папочная база — произвольная директория с .md, добавленная в реестр
// (KnowledgeBaseStore). Каждой папке — свой folder-rag.sqlite (переиспользуем
// RagIndex/MarkdownChunker/Vector задачи 13), синхронизация ленивая при
// первом ретриве (паттерн ProjectDocsIndexService задачи 25): произвольные
// папки меняются вне контроля приложения, FSEvents на каждую не вешаем.
//
// Лимиты загрузчика — предохранитель от «указал ~/Documents на 50 тыс.
// файлов»: эмбеддинги стоят денег/времени, молча жечь их нельзя.

import Foundation

/// Рекурсивный сбор .md-файлов папочной базы. Dot-элементы (в т.ч. .obsidian,
/// .git) пропускаются целиком.
enum FolderDocsLoader {
    /// Файл больше этого размера пропускается (это не заметка, а свалка).
    static let maxFileBytes = 1024 * 1024
    /// Максимум файлов на базу; лишние отбрасываются с сортировкой по пути —
    /// детерминированно, а не «какие успели».
    static let maxFiles = 2000

    /// (относительный путь, содержимое) в алфавитном порядке путей.
    static func loadFiles(root: URL) -> [(name: String, content: String)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let relative = relativePath(of: url, under: root)
            guard !relative.isEmpty else { continue }
            paths.append(relative)
        }
        var result: [(String, String)] = []
        for relative in paths.sorted().prefix(maxFiles) {
            if let content = readText(root.appendingPathComponent(relative)) {
                result.append((relative, content))
            }
        }
        return result
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return "" }
        return String(path.dropFirst(rootPath.count))
    }

    private static func readText(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size <= maxFileBytes else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Actor-владелец индексов папочных баз: сериализует доступ к RagIndex (он не
/// потокобезопасен) и кэширует открытые БД по пути папки.
actor FolderIndexService {
    /// Статистика индекса для настроек (та же форма, что у project-docs).
    struct Stats: Equatable {
        let files: Int
        let chunks: Int
        let updatedAt: Date?
    }

    private var cached: [String: RagIndex] = [:]

    /// Путь БД индекса папки: рядом с индексами vault, ключ — id пути.
    nonisolated static func indexFileURL(root: URL) -> URL {
        Config.appSupportDirectory
            .appendingPathComponent(VaultID.make(for: root), isDirectory: true)
            .appendingPathComponent("folder-rag.sqlite")
    }

    /// Top-K чанков по вопросу: ленивая синхронизация + поиск. Пустой массив
    /// при любой ошибке — RAG никогда не ломает отправку сообщения.
    func hits(root: URL,
              embedder: EmbeddingProvider,
              model: String?,
              tag: String,
              question: String,
              topK: Int) async -> [(path: String, heading: String,
                                    text: String, score: Float)] {
        do {
            let index = try openIndex(root: root)
            try await sync(index: index, root: root,
                           embedder: embedder, model: model, tag: tag)
            let (chunks, vectors) = try index.loadAll()
            guard !chunks.isEmpty,
                  let query = try await embedder.embed([question], model: model).first
            else { return [] }
            // Размерность запроса должна совпасть с индексом (сменили эмбеддер
            // без переиндексации — честный пустой результат).
            if let first = vectors.first, first.count != query.count { return [] }
            return Vector.topK(query: Vector.normalize(query), matrix: vectors, k: max(1, topK))
                .compactMap { hit in
                    guard hit.index >= 0, hit.index < chunks.count else { return nil }
                    let stored = chunks[hit.index]
                    return (path: stored.chunk.filePath,
                            heading: stored.chunk.headingPath,
                            text: stored.chunk.text,
                            score: hit.score)
                }
        } catch {
            return []
        }
    }

    /// nil — индекс ещё не строился (файла БД нет). Пустую БД НЕ создаёт.
    func stats(root: URL) -> Stats? {
        guard FileManager.default.fileExists(atPath: Self.indexFileURL(root: root).path),
              let index = try? openIndex(root: root),
              let stats = try? index.stats() else { return nil }
        return Stats(files: stats.files, chunks: stats.chunks, updatedAt: index.updatedAt)
    }

    /// Число чанков; nil — индекс не строился.
    func chunkCount(root: URL) -> Int? {
        stats(root: root)?.chunks
    }

    /// Полный сброс индекса папки (кнопка «Переиндексировать» в настройках).
    func reset(root: URL) {
        guard let index = try? openIndex(root: root) else { return }
        try? index.clearAll()
        index.embeddingTag = nil
        index.updatedAt = nil
    }

    // MARK: - Внутренности

    private func openIndex(root: URL) throws -> RagIndex {
        let path = Self.indexFileURL(root: root).path
        if let index = cached[path] { return index }
        let index = try RagIndex(path: path)
        cached[path] = index
        return index
    }

    /// Инкрементальная синхронизация по mtime; смена модели эмбеддинга
    /// (тег «model|dim») → полная переиндексация: векторы несовместимы.
    private func sync(index: RagIndex, root: URL,
                      embedder: EmbeddingProvider, model: String?, tag: String) async throws {
        if index.embeddingTag != tag {
            try index.clearAll()
            index.embeddingTag = tag
        }

        let files = FolderDocsLoader.loadFiles(root: root)
        let indexed = try index.fileMtimes()
        var seen = Set<String>()

        for (name, content) in files {
            seen.insert(name)
            let mtime = Self.mtime(of: root.appendingPathComponent(name)) ?? 0
            if let existing = indexed[name], existing == mtime { continue }

            let chunks = MarkdownChunker.chunk(text: content, filePath: name)
            guard !chunks.isEmpty else {
                try index.replaceFile(path: name, mtime: mtime, chunks: [])
                continue
            }
            let vectors = try await embedder.embed(chunks.map(\.text), model: model)
                .map(Vector.normalize)
            try index.replaceFile(path: name, mtime: mtime,
                                  chunks: Array(zip(chunks, vectors)))
        }

        // Удалённые из папки файлы убираем из индекса.
        for stale in indexed.keys where !seen.contains(stale) {
            try index.removeFile(path: stale)
        }
        index.updatedAt = Date()
    }

    private nonisolated static func mtime(of url: URL) -> TimeInterval? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
            .flatMap { ($0 as? Date)?.timeIntervalSince1970 }
    }
}
