// db.ts — открытие SQLite (better-sqlite3) + миграции (порт из agent-lab).
// WAL-режим, forward-only миграции, версия схемы — PRAGMA user_version.

import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type DB = Database.Database;

/** SQL-миграции по порядку. Индекс массива + 1 = целевая user_version. */
const MIGRATIONS: string[] = [
  // ── v1: настройки + журнал запросов (аудит) ─────────────────────────────────
  `
  CREATE TABLE settings (
    id                INTEGER PRIMARY KEY CHECK (id = 1),
    llm_url           TEXT NOT NULL DEFAULT 'https://api.deepseek.com/chat/completions',
    llm_api_key       TEXT NOT NULL DEFAULT '',
    model             TEXT NOT NULL DEFAULT 'deepseek-v4-flash',
    temperature       REAL NOT NULL DEFAULT 0.4,
    max_tokens        INTEGER NOT NULL DEFAULT 2000,
    system_prompt     TEXT NOT NULL DEFAULT '',
    input_policy      TEXT NOT NULL DEFAULT 'mask',
    prices_json       TEXT NOT NULL DEFAULT '{}',
    rate_limit_per_min INTEGER NOT NULL DEFAULT 20,
    daily_limit       INTEGER NOT NULL DEFAULT 1000,
    updated_at        TEXT NOT NULL DEFAULT ''
  );

  INSERT INTO settings (id, updated_at) VALUES (1, '');

  -- Аудит: один запрос через gateway = одна строка. Это и есть отчёт по домашке.
  CREATE TABLE requests (
    id                TEXT PRIMARY KEY,
    created_at        TEXT NOT NULL,
    ip                TEXT NOT NULL DEFAULT '',
    user_preview      TEXT NOT NULL DEFAULT '',
    input_findings_json TEXT NOT NULL DEFAULT '[]',
    input_action      TEXT NOT NULL DEFAULT 'allow',
    answer            TEXT NOT NULL DEFAULT '',
    output_verdict    TEXT NOT NULL DEFAULT 'pass',
    output_issues_json TEXT NOT NULL DEFAULT '[]',
    model             TEXT NOT NULL DEFAULT '',
    prompt_tokens     INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    total_tokens      INTEGER NOT NULL DEFAULT 0,
    cost_usd          REAL NOT NULL DEFAULT 0,
    blocked           INTEGER NOT NULL DEFAULT 0
  );

  CREATE INDEX idx_requests_created ON requests (created_at DESC);
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

/** Открывает БД (или ":memory:" для тестов), включает WAL и накатывает миграции. */
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
