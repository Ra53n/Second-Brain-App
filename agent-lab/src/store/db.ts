// db.ts — открытие SQLite (better-sqlite3) + миграции (порт из support/).
//
// WAL-режим, forward-only миграции, версия схемы — PRAGMA user_version.

import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type DB = Database.Database;

/** SQL-миграции по порядку. Индекс массива + 1 = целевая user_version. */
const MIGRATIONS: string[] = [
  // ── v1: исходная схема лаборатории ─────────────────────────────────────────
  `
  CREATE TABLE settings (
    id                   INTEGER PRIMARY KEY CHECK (id = 1),
    llm_url              TEXT NOT NULL DEFAULT 'https://api.deepseek.com/chat/completions',
    llm_api_key          TEXT NOT NULL DEFAULT '',
    model                TEXT NOT NULL DEFAULT 'deepseek-chat',
    temperature          REAL NOT NULL DEFAULT 0.3,
    max_tokens           INTEGER NOT NULL DEFAULT 1200,
    max_iterations       INTEGER NOT NULL DEFAULT 5,
    security_level       TEXT NOT NULL DEFAULT 'normal',
    search_provider      TEXT NOT NULL DEFAULT 'none',
    search_api_key       TEXT NOT NULL DEFAULT '',
    access_code_hash     TEXT NOT NULL DEFAULT '',
    daily_exchange_limit INTEGER NOT NULL DEFAULT 500,
    updated_at           TEXT NOT NULL DEFAULT ''
  );

  INSERT INTO settings (id, updated_at) VALUES (1, '');

  -- Подсадные флаги. Генерируются при первом старте, в git не попадают.
  CREATE TABLE flags (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    created_at TEXT NOT NULL
  );

  -- Сессия атакующего: opaque-токен в cookie, в БД только его sha256.
  CREATE TABLE lab_sessions (
    id         TEXT PRIMARY KEY,
    label      TEXT NOT NULL DEFAULT '',
    token_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_seen  TEXT NOT NULL
  );

  CREATE INDEX idx_lab_sessions_token ON lab_sessions (token_hash);

  CREATE TABLE messages (
    id         TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES lab_sessions(id) ON DELETE CASCADE,
    seq        INTEGER NOT NULL,
    role       TEXT NOT NULL,
    content    TEXT NOT NULL,
    created_at TEXT NOT NULL
  );

  CREATE INDEX idx_messages_session ON messages (session_id, seq);

  -- Журнал попыток: один обмен = одна строка. Это и есть отчёт по домашке.
  CREATE TABLE attempts (
    id             TEXT PRIMARY KEY,
    session_id     TEXT NOT NULL REFERENCES lab_sessions(id) ON DELETE CASCADE,
    created_at     TEXT NOT NULL,
    security_level TEXT NOT NULL,
    user_text      TEXT NOT NULL,
    answer_text    TEXT NOT NULL,
    tools_json     TEXT NOT NULL DEFAULT '[]',
    captured_json  TEXT NOT NULL DEFAULT '[]',
    quoted_json    TEXT NOT NULL DEFAULT '[]',
    exfil_json     TEXT NOT NULL DEFAULT '[]',
    blocked_json   TEXT NOT NULL DEFAULT '[]',
    usage_json     TEXT NOT NULL DEFAULT '{}'
  );

  CREATE INDEX idx_attempts_created ON attempts (created_at DESC);
  CREATE INDEX idx_attempts_session ON attempts (session_id, created_at);
  `,
];

/** Применяет недостающие миграции (идемпотентно). */
function migrate(db: DB): void {
  const current = db.pragma("user_version", { simple: true }) as number;
  for (let v = current; v < MIGRATIONS.length; v++) {
    const sql = MIGRATIONS[v]!;
    const tx = db.transaction(() => {
      db.exec(sql);
      db.pragma(`user_version = ${v + 1}`);
    });
    tx();
  }
}

/**
 * Открывает БД по пути (или ":memory:" для тестов), включает WAL и накатывает
 * миграции. Создаёт каталог при необходимости.
 */
export function openDb(path: string): DB {
  if (path !== ":memory:") {
    mkdirSync(dirname(path), { recursive: true });
  }
  const db = new Database(path);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.pragma("busy_timeout = 5000");
  migrate(db);
  return db;
}
