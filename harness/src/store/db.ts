// db.ts — SQLite (better-sqlite3) + миграции. WAL, forward-only по user_version.
// Порт gateway/src/store/db.ts.

import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type DB = Database.Database;

/** SQL-миграции по порядку. Индекс + 1 = целевая user_version. */
const MIGRATIONS: string[] = [
  // ── v1: прогоны FSM + журнал фаз ────────────────────────────────────────────
  `
  -- Один прогон execution loop = одна строка. ctx_json — весь RunContext целиком.
  CREATE TABLE runs (
    id           TEXT PRIMARY KEY,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    task_id      TEXT NOT NULL DEFAULT '',
    task_title   TEXT NOT NULL DEFAULT '',
    state        TEXT NOT NULL DEFAULT 'generating',
    status       TEXT NOT NULL DEFAULT 'running',
    outcome      TEXT NOT NULL DEFAULT '',
    round        INTEGER NOT NULL DEFAULT 1,
    secure       INTEGER NOT NULL DEFAULT 1,
    pwned        INTEGER NOT NULL DEFAULT 0,
    cost_usd     REAL NOT NULL DEFAULT 0,
    generation   INTEGER NOT NULL DEFAULT 0,
    ctx_json     TEXT NOT NULL DEFAULT '{}'
  );

  CREATE INDEX idx_runs_created ON runs (created_at DESC);

  -- Журнал фаз: по строке на каждый шаг. Секреты не пишем — только маскированные
  -- превью и метаданные (что поймал security step / что поймал gateway).
  CREATE TABLE steps (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id        TEXT NOT NULL,
    created_at    TEXT NOT NULL,
    round         INTEGER NOT NULL DEFAULT 0,
    phase         TEXT NOT NULL DEFAULT '',
    display       TEXT NOT NULL DEFAULT '',
    prompt_preview TEXT NOT NULL DEFAULT '',
    answer_preview TEXT NOT NULL DEFAULT '',
    findings_json TEXT NOT NULL DEFAULT '[]',
    gateway_json  TEXT NOT NULL DEFAULT '{}',
    egress_json   TEXT NOT NULL DEFAULT '[]',
    pwned         INTEGER NOT NULL DEFAULT 0,
    cost_usd      REAL NOT NULL DEFAULT 0
  );

  CREATE INDEX idx_steps_run ON steps (run_id, id);
  `,
  // ── v2: журнал замечаний корректности в шаге (переход на LLM-only loop) ──────
  `ALTER TABLE steps ADD COLUMN correctness_json TEXT NOT NULL DEFAULT '[]';`,
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
