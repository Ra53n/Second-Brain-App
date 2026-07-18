// RagIndexer.swift — пайплайн индексации vault (задача 13).
//
// Чистая оркестрация вне MainActor (тестируется напрямую на temp-vault +
// HashingEmbedder + :memory:-индексе): скан .md-файлов vault → сравнение
// mtime с индексом → ИЗМЕНЁННЫЕ файлы перечанковать/переэмбеддить (батчами),
// УДАЛЁННЫЕ выкинуть. Каждый файл коммитится своей транзакцией — прерывание
// (отмена/краш) оставляет уже обработанные файлы готовыми, повторный запуск
// доделывает остальное и не пересчитывает готовое (crash-safety).
//
// Инвалидация: тег модели эмбеддинга («model|dim») хранится в индексе;
// несовпадение с текущей моделью роутера → RagError.embeddingModelChanged —
// UI предлагает полную переиндексацию (векторы разных моделей несравнимы).

import Foundation

enum RagError: LocalizedError, Equatable {
    case noEmbeddingProvider
    case embeddingModelChanged(indexTag: String, currentTag: String)
    case vaultUnavailable

    var errorDescription: String? {
        switch self {
        case .noEmbeddingProvider:
            return "Нет доступного провайдера эмбеддингов. Добавьте API-ключ (OpenAI/Gemini) или скачайте локальную модель (nomic-embed-text)."
        case let .embeddingModelChanged(indexTag, currentTag):
            return "Модель эмбеддинга изменилась (\(indexTag) → \(currentTag)) — векторы несовместимы. Нужна полная переиндексация."
        case .vaultUnavailable:
            return "Vault не открыт — индексировать нечего."
        }
    }
}

/// Прогресс индексации для UI.
struct RagIndexProgress: Equatable, Sendable {
    var processed: Int = 0
    var total: Int = 0
    var currentFile: String = ""

    var fraction: Double {
        total > 0 ? Double(processed) / Double(total) : 0
    }
}

/// Итог одного прохода синхронизации.
struct RagSyncResult: Equatable {
    var indexedFiles: Int = 0   // перечанковано/переэмбеджено
    var removedFiles: Int = 0
    var skippedFiles: Int = 0   // mtime не изменился
}

enum RagIndexer {
    /// Размер батча эмбеддинга (у Ollama/OpenAI батч — один HTTP-запрос).
    static let embedBatchSize = 16

    /// Всегда исключаемые пути (относительные префиксы).
    static let builtinExcludes = ["Meetings/_recordings"]

    // MARK: - Скан vault

    /// Markdown-файлы vault: относительный путь → mtime. Исключаются dot-папки
    /// и файлы (enumerator пропускает скрытые), builtinExcludes и ignore-список
    /// пользователя (префиксы путей).
    static func scanVault(_ vaultURL: URL, ignore: [String] = []) -> [String: TimeInterval] {
        let excludes = builtinExcludes + ignore
        // resolvingSymlinksInPath с обеих сторон: /var/… и /private/var/… —
        // одно и то же место, но строковый префикс иначе не совпадёт.
        let root = vaultURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var result: [String: TimeInterval] = [:]
        for case let url as URL in enumerator {
            guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                           .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(prefix) else { continue }
            let relative = String(resolvedPath.dropFirst(prefix.count))
            guard !excludes.contains(where: { relative.hasPrefix($0) }) else { continue }
            result[relative] = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        return result
    }

    /// План инкрементального обновления: что переиндексировать, что удалить.
    /// Чистая функция — сравнение mtime с точностью до 1 мс.
    static func plan(vaultFiles: [String: TimeInterval],
                     indexedFiles: [String: TimeInterval]) -> (update: [String], remove: [String]) {
        var update: [String] = []
        for (path, mtime) in vaultFiles {
            if let indexed = indexedFiles[path], abs(indexed - mtime) < 0.001 { continue }
            update.append(path)
        }
        let remove = indexedFiles.keys.filter { vaultFiles[$0] == nil }
        return (update.sorted(), remove.sorted())
    }

    // MARK: - Синхронизация

    /// Инкрементальная синхронизация индекса с vault. `embeddingTag` — тег
    /// текущей модели («model|dim»); несовпадение с индексом → ошибка
    /// (вызывающий предлагает fullReindex). Прогресс — по файлам.
    @discardableResult
    static func sync(vaultURL: URL,
                     index: RagIndex,
                     embedder: EmbeddingProvider,
                     embeddingModel: String? = nil,
                     embeddingTag: String,
                     ignore: [String] = [],
                     progress: (@Sendable (RagIndexProgress) -> Void)? = nil) async throws -> RagSyncResult {
        // Инвалидация: индекс построен другой моделью.
        if let existing = index.embeddingTag, existing != embeddingTag {
            throw RagError.embeddingModelChanged(indexTag: existing, currentTag: embeddingTag)
        }

        let vaultFiles = scanVault(vaultURL, ignore: ignore)
        let indexedFiles = try index.fileMtimes()
        let (toUpdate, toRemove) = plan(vaultFiles: vaultFiles, indexedFiles: indexedFiles)

        var result = RagSyncResult(skippedFiles: vaultFiles.count - toUpdate.count)

        for path in toRemove {
            try Task.checkCancellation()
            try index.removeFile(path: path)
            result.removedFiles += 1
        }

        for (offset, path) in toUpdate.enumerated() {
            try Task.checkCancellation()
            progress?(RagIndexProgress(processed: offset, total: toUpdate.count, currentFile: path))
            let url = vaultURL.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                // Файл исчез/нечитаем между сканом и чтением — пропускаем,
                // следующий проход разберётся.
                continue
            }
            let chunks = MarkdownChunker.chunk(text: text, filePath: path)
            var pairs: [(chunk: RagChunk, vector: [Float])] = []
            // Эмбеддинги батчами; пустая заметка — файл фиксируется без чанков
            // (mtime записан, чтобы не перечитывать её каждый проход).
            var start = 0
            while start < chunks.count {
                try Task.checkCancellation()
                let end = min(start + embedBatchSize, chunks.count)
                let batch = Array(chunks[start..<end])
                let vectors = try await embedder.embed(batch.map(\.text), model: embeddingModel)
                guard vectors.count == batch.count else {
                    throw LLMError.emptyResponse
                }
                pairs.append(contentsOf: zip(batch, vectors).map { ($0, $1) })
                start = end
            }
            // Коммит файла одной транзакцией — граница crash-safety.
            try index.replaceFile(path: path,
                                  mtime: vaultFiles[path] ?? 0,
                                  chunks: pairs)
            result.indexedFiles += 1
        }

        index.embeddingTag = embeddingTag
        index.updatedAt = Date()
        progress?(RagIndexProgress(processed: toUpdate.count, total: toUpdate.count))
        return result
    }
}
