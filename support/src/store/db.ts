// db.ts — открытие SQLite (better-sqlite3) + миграции (порт из manager-agent).
//
// WAL-режим, forward-only миграции, версия схемы — PRAGMA user_version.

import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type DB = Database.Database;

/** SQL-миграции по порядку. Индекс массива + 1 = целевая user_version. */
const MIGRATIONS: string[] = [
  // ── v1: исходная схема ─────────────────────────────────────────────────────
  `
  CREATE TABLE users (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    email         TEXT NOT NULL DEFAULT '',
    password_hash TEXT NOT NULL,
    is_admin      INTEGER NOT NULL DEFAULT 0,
    settings_json TEXT NOT NULL DEFAULT '{}',
    created_at    TEXT NOT NULL
  );

  CREATE TABLE user_sessions (
    id         TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    last_seen  TEXT NOT NULL
  );

  CREATE INDEX idx_user_sessions_token ON user_sessions (token_hash);

  CREATE TABLE settings (
    id             INTEGER PRIMARY KEY CHECK (id = 1),
    provider       TEXT NOT NULL DEFAULT 'ollama',
    llm_api_key    TEXT NOT NULL DEFAULT '',
    remote_model   TEXT NOT NULL DEFAULT 'deepseek-chat',
    local_model    TEXT NOT NULL DEFAULT 'qwen3:4b-instruct-2507-q4_K_M',
    embed_model    TEXT NOT NULL DEFAULT 'bge-m3',
    system_prompt  TEXT NOT NULL DEFAULT '',
    rag_json       TEXT NOT NULL DEFAULT '{}',
    max_iterations INTEGER NOT NULL DEFAULT 4,
    updated_at     TEXT NOT NULL DEFAULT ''
  );

  INSERT INTO settings (id, updated_at) VALUES (1, '');

  CREATE TABLE mcp_servers (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL DEFAULT '',
    command    TEXT NOT NULL DEFAULT 'node',
    args_json  TEXT NOT NULL DEFAULT '[]',
    env_json   TEXT NOT NULL DEFAULT '{}',
    enabled    INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL DEFAULT ''
  );

  CREATE TABLE chat_sessions (
    id         TEXT PRIMARY KEY,
    user_id    TEXT REFERENCES users(id) ON DELETE CASCADE,
    title      TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE chat_messages (
    id              TEXT PRIMARY KEY,
    session_id      TEXT NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
    seq             INTEGER NOT NULL,
    role            TEXT NOT NULL,
    content         TEXT NOT NULL,
    usage_json      TEXT,
    tool_calls_json TEXT NOT NULL DEFAULT '[]',
    created_at      TEXT NOT NULL
  );

  CREATE INDEX idx_chat_messages_session ON chat_messages (session_id, seq);
  CREATE INDEX idx_chat_sessions_user ON chat_sessions (user_id, updated_at DESC, id DESC);

  CREATE TABLE kb_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT ''
  );

  CREATE TABLE kb_chunks (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    path    TEXT NOT NULL,
    section TEXT NOT NULL DEFAULT '',
    ordinal INTEGER NOT NULL,
    text    TEXT NOT NULL,
    vec     BLOB NOT NULL,
    dim     INTEGER NOT NULL
  );
  `,

  // ── v2: привязка чата к CRM-тикету (фидбек «решено/не решено» обновляет
  //   одно и то же обращение, а не плодит новые) ─────────────────────────────
  `
  ALTER TABLE chat_sessions ADD COLUMN ticket_id TEXT NOT NULL DEFAULT '';
  `,
];

/** Применяет недостающие миграции (idempotent). */
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
