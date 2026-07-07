// SearchIndex.swift — полнотекстовый поиск по vault: SQLite FTS5, system libsqlite3.
//
// Эталон — RagSQLiteIndex из MA: import SQLite3 без SwiftPM-зависимостей,
// prepared statements, «:memory:» в тестах.
//
// Схема:
//   files(id INTEGER PRIMARY KEY, path TEXT UNIQUE, mtime REAL) — учёт mtime;
//   notes — FTS5(path UNINDEXED, title, body), rowid = files.id, токенизатор
//   unicode61 (регистронезависимая кириллица из коробки).
//
// Индекс — производные данные (инвариант №1): живёт в Application Support
// (<vault-id>/search.sqlite), пересоздаваем командой «Пересоздать индекс».
//
// Потоки: класс НЕ потокобезопасен; все вызовы — с одной серийной очереди
// (SearchViewModel.indexQueue). UI получает результаты через async-прыжок на main.

import Foundation
import SQLite3

/// Результат поиска: файл + сниппет с маркерами совпадений.
struct SearchHit: Equatable {
    let path: String
    /// Имя файла без расширения (колонка title).
    let title: String
    /// Сниппет FTS5; совпадения обёрнуты в \u{1}…\u{2} (для жирного в UI).
    let snippet: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// Ошибки поискового индекса — с текстом SQLite, пригодным для показа.
enum SearchIndexError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): return "Поисковый индекс: \(message)"
        }
    }
}

/// FTS5-индекс заметок. Один экземпляр на открытый vault.
final class SearchIndex {

    /// Маркеры совпадений в сниппете — непечатаемые, в заметках не встречаются.
    static let matchStart = "\u{1}"
    static let matchEnd = "\u{2}"

    /// Деструктор SQLITE_TRANSIENT — просим SQLite скопировать буфер (как в MA).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?

    /// Путь БД для vault: Application Support/SecondBrain/<vault-id>/search.sqlite.
    static func databaseURL(vaultID: String) -> URL {
        Config.appSupportDirectory
            .appendingPathComponent(vaultID, isDirectory: true)
            .appendingPathComponent("search.sqlite")
    }

    /// - Parameter path: путь файла БД или «:memory:» (тесты).
    init(path: String) throws {
        if path != ":memory:" {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        guard sqlite3_open(path, &db) == SQLITE_OK, db != nil else {
            throw SearchIndexError.sqlite("не удалось открыть БД: \(Self.lastError(db))")
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY,
            path TEXT UNIQUE NOT NULL,
            mtime REAL NOT NULL
        );
        """)
        try exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS notes USING fts5(
            path UNINDEXED, title, body,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Индексация

    /// Инкрементальная синхронизация с vault: новые/изменённые файлы (по mtime)
    /// переиндексируются, пропавшие удаляются. Первый вызов на пустой БД —
    /// полная индексация. Возвращает true, если индекс изменился.
    @discardableResult
    func refresh(root: URL) throws -> Bool {
        var known: [String: Double] = [:]
        let select = try prepare("SELECT path, mtime FROM files;")
        defer { sqlite3_finalize(select) }
        while sqlite3_step(select) == SQLITE_ROW {
            known[String(cString: sqlite3_column_text(select, 0))] = sqlite3_column_double(select, 1)
        }

        var changed = false
        var seen = Set<String>()
        try exec("BEGIN TRANSACTION;")
        do {
            for url in VaultScanner.markdownFiles(in: root) {
                let path = url.path
                seen.insert(path)
                let mtime = VaultScanner.modificationDate(of: url)?.timeIntervalSince1970 ?? 0
                // Сравнение с эпсилоном: REAL в SQLite теряет наносекунды APFS.
                if let existing = known[path], abs(existing - mtime) < 0.001 { continue }
                try removeFileInTransaction(path: path)
                try insertFile(url: url, mtime: mtime)
                changed = true
            }
            for path in known.keys where !seen.contains(path) {
                try removeFileInTransaction(path: path)
                changed = true
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        return changed
    }

    /// Полное пересоздание («Пересоздать индекс» — на случай рассинхрона).
    func rebuild(root: URL) throws {
        try exec("DELETE FROM notes;")
        try exec("DELETE FROM files;")
        try refresh(root: root)
    }

    // MARK: - Поиск

    /// Поиск по запросу пользователя. Пустой/несловесный запрос → пусто.
    /// Ранжирование bm25 (ORDER BY rank), совпадения в сниппете — \u{1}…\u{2}.
    func search(_ userQuery: String, limit: Int = 50) throws -> [SearchHit] {
        guard let match = Self.ftsQuery(from: userQuery) else { return [] }
        let stmt = try prepare("""
        SELECT path, title, snippet(notes, 2, ?, ?, '…', 12)
        FROM notes WHERE notes MATCH ? ORDER BY rank LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, Self.matchStart, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, Self.matchEnd, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, match, -1, Self.transient)
        sqlite3_bind_int(stmt, 4, Int32(limit))

        var hits: [SearchHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            hits.append(SearchHit(
                path: String(cString: sqlite3_column_text(stmt, 0)),
                title: String(cString: sqlite3_column_text(stmt, 1)),
                snippet: String(cString: sqlite3_column_text(stmt, 2))
            ))
        }
        return hits
    }

    /// Пользовательский ввод → FTS5 MATCH: каждое слово в кавычках с «*»
    /// (префиксный поиск, неявный AND). Кавычки внутри слов гасятся удвоением.
    /// nil — в запросе нет ни одного словесного токена.
    static func ftsQuery(from userQuery: String) -> String? {
        let tokens = userQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }

    // MARK: - Внутреннее

    private func insertFile(url: URL, mtime: Double) throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let title = url.deletingPathExtension().lastPathComponent

        let insertFile = try prepare("INSERT INTO files (path, mtime) VALUES (?, ?);")
        defer { sqlite3_finalize(insertFile) }
        sqlite3_bind_text(insertFile, 1, url.path, -1, Self.transient)
        sqlite3_bind_double(insertFile, 2, mtime)
        guard sqlite3_step(insertFile) == SQLITE_DONE else {
            throw SearchIndexError.sqlite("insert files: \(Self.lastError(db))")
        }
        let rowID = sqlite3_last_insert_rowid(db)

        let insertNote = try prepare("INSERT INTO notes (rowid, path, title, body) VALUES (?, ?, ?, ?);")
        defer { sqlite3_finalize(insertNote) }
        sqlite3_bind_int64(insertNote, 1, rowID)
        sqlite3_bind_text(insertNote, 2, url.path, -1, Self.transient)
        sqlite3_bind_text(insertNote, 3, title, -1, Self.transient)
        sqlite3_bind_text(insertNote, 4, text, -1, Self.transient)
        guard sqlite3_step(insertNote) == SQLITE_DONE else {
            throw SearchIndexError.sqlite("insert notes: \(Self.lastError(db))")
        }
    }

    /// Удаление файла из обеих таблиц (по files.id ↔ notes.rowid).
    private func removeFileInTransaction(path: String) throws {
        let selectID = try prepare("SELECT id FROM files WHERE path = ?;")
        defer { sqlite3_finalize(selectID) }
        sqlite3_bind_text(selectID, 1, path, -1, Self.transient)
        guard sqlite3_step(selectID) == SQLITE_ROW else { return } // не был проиндексирован
        let rowID = sqlite3_column_int64(selectID, 0)

        let deleteNote = try prepare("DELETE FROM notes WHERE rowid = ?;")
        defer { sqlite3_finalize(deleteNote) }
        sqlite3_bind_int64(deleteNote, 1, rowID)
        guard sqlite3_step(deleteNote) == SQLITE_DONE else {
            throw SearchIndexError.sqlite("delete notes: \(Self.lastError(db))")
        }

        let deleteFile = try prepare("DELETE FROM files WHERE id = ?;")
        defer { sqlite3_finalize(deleteFile) }
        sqlite3_bind_int64(deleteFile, 1, rowID)
        guard sqlite3_step(deleteFile) == SQLITE_DONE else {
            throw SearchIndexError.sqlite("delete files: \(Self.lastError(db))")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SearchIndexError.sqlite("prepare: \(Self.lastError(db))")
        }
        return stmt
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "неизвестная ошибка"
            sqlite3_free(err)
            throw SearchIndexError.sqlite("\(sql.prefix(40)) → \(message)")
        }
    }

    private static func lastError(_ db: OpaquePointer?) -> String {
        guard let db else { return "нет соединения" }
        return String(cString: sqlite3_errmsg(db))
    }
}
