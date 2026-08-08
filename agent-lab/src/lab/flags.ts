// flags.ts — подсадные флаги лаборатории.
//
// Генерируются при первом старте и лежат в БД: в репозитории их нет, у каждой
// установки они свои. Показываются только в админке — иначе владелец не сможет
// проверить журнал попыток, а атакующий получит ответ даром.

import { randomBytes } from "node:crypto";
import type { DB } from "../store/db.js";
import { FLAG_KEYS, type Flag, type FlagKey } from "../domain/types.js";

/** Формат флага: SBLAB{<где спрятан>-<24 hex>}. */
export function generateFlag(key: FlagKey): string {
  return `SBLAB{${key}-${randomBytes(12).toString("hex")}}`;
}

export class FlagsRepo {
  constructor(
    private readonly db: DB,
    private readonly now: () => Date = () => new Date(),
  ) {}

  /** Досоздаёт недостающие флаги. Существующие не трогает (идемпотентно). */
  ensure(): Flag[] {
    const insert = this.db.prepare(
      "INSERT OR IGNORE INTO flags (key, value, created_at) VALUES (?, ?, ?)",
    );
    const stamp = this.now().toISOString();
    for (const key of FLAG_KEYS) insert.run(key, generateFlag(key), stamp);
    return this.list();
  }

  list(): Flag[] {
    const rows = this.db.prepare("SELECT key, value, created_at FROM flags").all() as Array<{
      key: string;
      value: string;
      created_at: string;
    }>;
    return rows
      .filter((r) => FLAG_KEYS.includes(r.key as FlagKey))
      .map((r) => ({ key: r.key as FlagKey, value: r.value, createdAt: r.created_at }));
  }

  get(key: FlagKey): string {
    return this.list().find((f) => f.key === key)?.value ?? "";
  }

  /** Перевыпуск всех флагов — «начать игру заново» из админки. */
  rotate(): Flag[] {
    const stamp = this.now().toISOString();
    const upsert = this.db.prepare(
      `INSERT INTO flags (key, value, created_at) VALUES (?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value, created_at = excluded.created_at`,
    );
    for (const key of FLAG_KEYS) upsert.run(key, generateFlag(key), stamp);
    return this.list();
  }
}
