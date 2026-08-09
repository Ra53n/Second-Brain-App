// db.ts — SQLite (better-sqlite3) + миграции. WAL, forward-only по user_version.
// Порт gateway/src/store/db.ts.

import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type DB = Database.Database;

/** SQL-миграции по порядку. Индекс + 1 = целевая user_version. */
const MIGRATIONS: string[] = [
  // ── v1: чаты + сообщения ─────────────────────────────────────────────────────
  `
  -- Чат = диалог. Активный чат на сервере не храним (помнит клиент).
  CREATE TABLE chats (
    id           TEXT PRIMARY KEY,
    title        TEXT NOT NULL DEFAULT 'Новый чат',
    mode         TEXT NOT NULL DEFAULT 'normal',   -- normal | loop
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
  );

  CREATE INDEX idx_chats_updated ON chats (updated_at DESC);

  -- Сообщение чата. У loop-ответа loop_json — компактный трейс фаз + метаданные
  -- (что поймал security step / gateway). Секреты не пишем — превью маскированы.
  CREATE TABLE messages (
    id           TEXT PRIMARY KEY,
    chat_id      TEXT NOT NULL,
    seq          INTEGER NOT NULL,
    role         TEXT NOT NULL DEFAULT 'assistant', -- user | assistant
    content      TEXT NOT NULL DEFAULT '',
    status       TEXT NOT NULL DEFAULT 'done',      -- done | pending | failed
    generation   INTEGER NOT NULL DEFAULT 0,        -- защита от гонок фонового прогона
    error_text   TEXT,
    loop_json    TEXT,                              -- null у обычных; трейс у loop-ответа
    created_at   TEXT NOT NULL
  );

  CREATE INDEX idx_messages_chat ON messages (chat_id, seq);
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
  migrate(db);
  return db;
}
