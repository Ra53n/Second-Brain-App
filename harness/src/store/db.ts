// db.ts — SQLite (better-sqlite3) + миграции. WAL, forward-only по user_version.
// Порт gateway/src/store/db.ts.

import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type DB = Database.Database;

/** SQL-миграции по порядку. Индекс + 1 = целевая user_version. Строго
 *  forward-only и аддитивно: v1 (задача 105) не переписывается — БД задачи 105
 *  уже на user_version=1, и v2 её обновляет. */
const MIGRATIONS: string[] = [
  // ── v1: чаты + сообщения (задача 105, без пользователей) ─────────────────────
  `
  CREATE TABLE chats (
    id           TEXT PRIMARY KEY,
    title        TEXT NOT NULL DEFAULT 'Новый чат',
    mode         TEXT NOT NULL DEFAULT 'normal',
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
  );
  CREATE INDEX idx_chats_updated ON chats (updated_at DESC);

  CREATE TABLE messages (
    id           TEXT PRIMARY KEY,
    chat_id      TEXT NOT NULL,
    seq          INTEGER NOT NULL,
    role         TEXT NOT NULL DEFAULT 'assistant',
    content      TEXT NOT NULL DEFAULT '',
    status       TEXT NOT NULL DEFAULT 'done',
    generation   INTEGER NOT NULL DEFAULT 0,
    error_text   TEXT,
    loop_json    TEXT,
    created_at   TEXT NOT NULL
  );
  CREATE INDEX idx_messages_chat ON messages (chat_id, seq);
  `,
  // ── v2: авторизация (задача 106) — пользователи, сессии, чаты per-user ────────
  // Старые чаты/сообщения задачи 105 — анонимные тестовые данные без владельца;
  // безопасно пересоздать таблицы под новую схему (реальных пользователей ещё нет).
  `
  CREATE TABLE users (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    is_admin      INTEGER NOT NULL DEFAULT 0,
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

  DROP TABLE messages;
  DROP TABLE chats;

  CREATE TABLE chats (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title        TEXT NOT NULL DEFAULT 'Новый чат',
    mode         TEXT NOT NULL DEFAULT 'normal',
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
  );
  CREATE INDEX idx_chats_user ON chats (user_id, updated_at DESC);

  -- alert/alert_kinds — денормализованный сигнал для фильтра админки (как
  -- interceptions в gateway). Секреты не пишем — превью маскированы.
  CREATE TABLE messages (
    id           TEXT PRIMARY KEY,
    chat_id      TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL,
    role         TEXT NOT NULL DEFAULT 'assistant',
    content      TEXT NOT NULL DEFAULT '',
    status       TEXT NOT NULL DEFAULT 'done',
    generation   INTEGER NOT NULL DEFAULT 0,
    error_text   TEXT,
    loop_json    TEXT,
    alert        INTEGER NOT NULL DEFAULT 0,
    alert_kinds  TEXT NOT NULL DEFAULT '[]',
    created_at   TEXT NOT NULL
  );
  CREATE INDEX idx_messages_chat ON messages (chat_id, seq);
  CREATE INDEX idx_messages_alert ON messages (alert, created_at DESC);
  `,
];

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

export function openDb(path: string): DB {
  if (path !== ":memory:") {
    mkdirSync(dirname(path), { recursive: true });
  }
  const db = new Database(path);
  db.pragma("journal_mode = WAL");
  db.pragma("busy_timeout = 5000");
  db.pragma("foreign_keys = ON"); // каскад удаления сессий/чатов/сообщений
  migrate(db);
  return db;
}
