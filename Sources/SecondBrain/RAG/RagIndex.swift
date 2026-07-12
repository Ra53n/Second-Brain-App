// RagIndex.swift — SQLite-хранилище RAG-индекса (задача 13).
//
// Системный `import SQLite3` (libsqlite3 из SDK, без SwiftPM-зависимостей —
// как в MA). Отличие от MA: чанки и векторы живут ВМЕСТЕ в одной БД с
// пофайловой инкрементальностью (у MA — JSON-файлы и полная переиндексация).
//
// Схема:
//   meta(key TEXT PK, value TEXT)                    — модель эмбеддинга, даты
//   files(path TEXT PK, mtime REAL)                  — что и когда индексировано
//   chunks(id PK, path, heading, line_start, line_end, text, vec BLOB, dim)
//
// Вектор — Float32 little-endian BLOB (формат RagFileIO из MA). Обновление
// файла — одна транзакция (delete старых чанков + insert новых + upsert mtime):
// прерывание пайплайна оставляет БД консистентной на границе файла, уже
// проиндексированные файлы не пересчитываются (crash-safety задачи 13).
//
// Путь: ~/Library/Application Support/SecondBrain/<vault-id>/rag.sqlite;
// в тестах — ":memory:".

import Foundation
import SQLite3

enum RagIndexError: LocalizedError {
    case io(String)
    case badFormat(String)

    var errorDescription: String? {
        switch self {
        case .io(let s): return "Ошибка RAG-индекса: \(s)"
        case .badFormat(let s): return "Повреждённый RAG-индекс: \(s)"
        }
    }
}

/// Чанк, прочитанный из индекса (с ключом БД).
struct StoredRagChunk: Equatable, Identifiable {
    var id: Int64
    var chunk: RagChunk
}

/// Обёртка над одной БД rag.sqlite. НЕ потокобезопасна — владелец
/// (RagIndexManager) сериализует доступ.
final class RagIndex {
    private var db: OpaquePointer?
    /// SQLITE_TRANSIENT: просим SQLite скопировать переданный буфер.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Путь БД для vault в Application Support.
    static func fileURL(vaultID: String) -> URL {
        Config.appSupportDirectory
            .appendingPathComponent(vaultID, isDirectory: true)
            .appendingPathComponent("rag.sqlite")
    }

    /// path — файл БД либо ":memory:" (тесты).
    init(path: String) throws {
        if path != ":memory:" {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK, db != nil else {
            throw RagIndexError.io("не удалось открыть БД: \(Self.lastError(db))")
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, mtime REAL);
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            heading TEXT NOT NULL DEFAULT '',
            line_start INTEGER NOT NULL DEFAULT 0,
            line_end INTEGER NOT NULL DEFAULT 0,
            text TEXT NOT NULL,
            vec BLOB,
            dim INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS chunks_path ON chunks(path);
        """)
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: - Метаданные

    /// Тег модели эмбеддинга («model|dim»): несовпадение с текущей моделью
    /// роутера означает несовместимые векторы → нужна полная переиндексация.
    var embeddingTag: String? {
        get { metaValue(forKey: "embeddingTag") }
        set { try? setMetaValue(newValue, forKey: "embeddingTag") }
    }

    /// Момент последнего успешного обновления (для UI).
    var updatedAt: Date? {
        get { metaValue(forKey: "updatedAt").flatMap { Double($0) }
                .map { Date(timeIntervalSince1970: $0) } }
        set { try? setMetaValue(newValue.map { String($0.timeIntervalSince1970) },
                                forKey: "updatedAt") }
    }

    // MARK: - Файлы

    /// Все проиндексированные файлы с их mtime (база инкрементальности).
    func fileMtimes() throws -> [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        let stmt = try prepare("SELECT path, mtime FROM files;")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            result[path] = sqlite3_column_double(stmt, 1)
        }
        return result
    }

    /// Атомарная замена содержимого файла: старые чанки долой, новые (с
    /// векторами) внутрь, mtime зафиксирован — всё одной транзакцией.
    func replaceFile(path: String,
                     mtime: TimeInterval,
                     chunks: [(chunk: RagChunk, vector: [Float])]) throws {
        try exec("BEGIN TRANSACTION;")
        do {
            try run("DELETE FROM chunks WHERE path = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, path, -1, Self.transient)
            }
            let insert = try prepare("""
            INSERT INTO chunks (path, heading, line_start, line_end, text, vec, dim)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(insert) }
            for (chunk, vector) in chunks {
                sqlite3_reset(insert)
                sqlite3_bind_text(insert, 1, path, -1, Self.transient)
                sqlite3_bind_text(insert, 2, chunk.headingPath, -1, Self.transient)
                sqlite3_bind_int(insert, 3, Int32(chunk.lineStart))
                sqlite3_bind_int(insert, 4, Int32(chunk.lineEnd))
                sqlite3_bind_text(insert, 5, chunk.text, -1, Self.transient)
                var blob = Data()
                blob.reserveCapacity(vector.count * 4)
                for value in vector {
                    withUnsafeBytes(of: value.bitPattern.littleEndian) { blob.append(contentsOf: $0) }
                }
                _ = blob.withUnsafeBytes { raw in
                    sqlite3_bind_blob(insert, 6, raw.baseAddress, Int32(blob.count), Self.transient)
                }
                sqlite3_bind_int(insert, 7, Int32(vector.count))
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw RagIndexError.io("insert chunk: \(Self.lastError(db))")
                }
            }
            try run("INSERT INTO files (path, mtime) VALUES (?, ?) " +
                    "ON CONFLICT(path) DO UPDATE SET mtime = excluded.mtime;") { stmt in
                sqlite3_bind_text(stmt, 1, path, -1, Self.transient)
                sqlite3_bind_double(stmt, 2, mtime)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Удаление файла из индекса (заметку удалили из vault).
    func removeFile(path: String) throws {
        try exec("BEGIN TRANSACTION;")
        do {
            try run("DELETE FROM chunks WHERE path = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, path, -1, Self.transient)
            }
            try run("DELETE FROM files WHERE path = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, path, -1, Self.transient)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Полная очистка (смена модели эмбеддинга → переиндексация с нуля).
    func clearAll() throws {
        try exec("DELETE FROM chunks; DELETE FROM files; DELETE FROM meta;")
    }

    // MARK: - Чтение для ретрива

    /// Все чанки с векторами (порядок стабилен по id). Для личного vault
    /// (тысячи чанков) читать всё целиком — миллисекунды.
    func loadAll() throws -> (chunks: [StoredRagChunk], vectors: [[Float]]) {
        var chunks: [StoredRagChunk] = []
        var vectors: [[Float]] = []
        let stmt = try prepare("""
        SELECT id, path, heading, line_start, line_end, text, vec, dim
        FROM chunks ORDER BY id ASC;
        """)
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let chunk = RagChunk(
                filePath: String(cString: sqlite3_column_text(stmt, 1)),
                headingPath: String(cString: sqlite3_column_text(stmt, 2)),
                lineStart: Int(sqlite3_column_int(stmt, 3)),
                lineEnd: Int(sqlite3_column_int(stmt, 4)),
                text: String(cString: sqlite3_column_text(stmt, 5)))
            let dim = Int(sqlite3_column_int(stmt, 7))
            var vector = [Float](repeating: 0, count: dim)
            if let raw = sqlite3_column_blob(stmt, 6) {
                let byteCount = Int(sqlite3_column_bytes(stmt, 6))
                let bytes = [UInt8](UnsafeRawBufferPointer(start: raw, count: byteCount))
                var offset = 0
                for i in 0..<dim where offset + 4 <= byteCount {
                    let u = UInt32(bytes[offset])
                        | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16)
                        | (UInt32(bytes[offset + 3]) << 24)
                    vector[i] = Float(bitPattern: u)
                    offset += 4
                }
            }
            chunks.append(StoredRagChunk(id: id, chunk: chunk))
            vectors.append(vector)
        }
        return (chunks, vectors)
    }

    /// Статистика для UI: (файлов, чанков).
    func stats() throws -> (files: Int, chunks: Int) {
        (try scalarInt("SELECT COUNT(*) FROM files;"),
         try scalarInt("SELECT COUNT(*) FROM chunks;"))
    }

    // MARK: - Внутренности

    private func metaValue(forKey key: String) -> String? {
        guard let stmt = try? prepare("SELECT value FROM meta WHERE key = ?;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    private func setMetaValue(_ value: String?, forKey key: String) throws {
        if let value {
            try run("INSERT INTO meta (key, value) VALUES (?, ?) " +
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value;") { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, Self.transient)
                sqlite3_bind_text(stmt, 2, value, -1, Self.transient)
            }
        } else {
            try run("DELETE FROM meta WHERE key = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, Self.transient)
            }
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw RagIndexError.io("prepare: \(Self.lastError(db))")
        }
        return stmt
    }

    /// Подготовить-забиндить-выполнить один DML-стейтмент.
    private func run(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw RagIndexError.io("\(sql) → \(Self.lastError(db))")
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "неизвестная ошибка"
            sqlite3_free(err)
            throw RagIndexError.io("\(sql.prefix(40)) → \(message)")
        }
    }

    private static func lastError(_ db: OpaquePointer?) -> String {
        guard let db else { return "нет соединения" }
        return String(cString: sqlite3_errmsg(db))
    }
}
