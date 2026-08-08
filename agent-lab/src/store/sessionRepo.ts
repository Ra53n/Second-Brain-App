// sessionRepo.ts — сессии атакующих и история их сообщений.
//
// Сессия = opaque-токен в httpOnly-cookie; в БД лежит только его sha256 — так
// сессию можно мгновенно отозвать, а из дампа БД токен не восстановить.
// В отличие от гостевого чата support/ историю хранит СЕРВЕР: транскрипты
// попыток и есть цель лаборатории.

import { createHash, randomBytes, randomUUID } from "node:crypto";
import type { DB } from "./db.js";
import type { LabSession } from "../domain/types.js";

const SESSION_TTL_MS = 14 * 24 * 60 * 60 * 1000;
/** Сколько последних сообщений уходит в модель (окно истории). */
export const HISTORY_WINDOW = 20;

export interface HistoryMessage {
  role: "user" | "assistant";
  content: string;
}

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export class SessionRepo {
  constructor(
    private readonly db: DB,
    private readonly now: () => Date = () => new Date(),
  ) {}

  /** Создаёт сессию, возвращает её и токен для cookie (в БД токена нет). */
  create(label: string): { session: LabSession; token: string } {
    const token = randomBytes(32).toString("hex");
    const stamp = this.now().toISOString();
    const session: LabSession = {
      id: randomUUID(),
      label: label.trim().slice(0, 60),
      createdAt: stamp,
      lastSeen: stamp,
    };
    this.db
      .prepare(
        "INSERT INTO lab_sessions (id, label, token_hash, created_at, last_seen) VALUES (?, ?, ?, ?, ?)",
      )
      .run(session.id, session.label, hashToken(token), stamp, stamp);
    return { session, token };
  }

  /** Находит живую сессию по токену из cookie и отмечает активность. */
  touch(token: string): LabSession | null {
    const row = this.db
      .prepare("SELECT * FROM lab_sessions WHERE token_hash = ?")
      .get(hashToken(token)) as Record<string, string> | undefined;
    if (!row) return null;
    const created = Date.parse(String(row.created_at));
    if (Number.isFinite(created) && this.now().getTime() - created > SESSION_TTL_MS) {
      this.db.prepare("DELETE FROM lab_sessions WHERE id = ?").run(row.id);
      return null;
    }
    const stamp = this.now().toISOString();
    this.db.prepare("UPDATE lab_sessions SET last_seen = ? WHERE id = ?").run(stamp, row.id);
    return {
      id: String(row.id),
      label: String(row.label ?? ""),
      createdAt: String(row.created_at),
      lastSeen: stamp,
    };
  }

  list(): LabSession[] {
    const rows = this.db
      .prepare("SELECT * FROM lab_sessions ORDER BY last_seen DESC")
      .all() as Array<Record<string, string>>;
    return rows.map((r) => ({
      id: String(r.id),
      label: String(r.label ?? ""),
      createdAt: String(r.created_at),
      lastSeen: String(r.last_seen),
    }));
  }

  appendMessage(sessionId: string, role: "user" | "assistant", content: string): void {
    const seq =
      (this.db
        .prepare("SELECT COALESCE(MAX(seq), 0) AS m FROM messages WHERE session_id = ?")
        .get(sessionId) as { m: number }).m + 1;
    this.db
      .prepare(
        "INSERT INTO messages (id, session_id, seq, role, content, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      )
      .run(randomUUID(), sessionId, seq, role, content, this.now().toISOString());
  }

  /** Последние сообщения сессии в хронологическом порядке. */
  history(sessionId: string, limit = HISTORY_WINDOW): HistoryMessage[] {
    const rows = this.db
      .prepare("SELECT role, content FROM messages WHERE session_id = ? ORDER BY seq DESC LIMIT ?")
      .all(sessionId, limit) as Array<{ role: string; content: string }>;
    return rows
      .reverse()
      .filter((r) => r.role === "user" || r.role === "assistant")
      .map((r) => ({ role: r.role as "user" | "assistant", content: r.content }));
  }

  clear(sessionId: string): void {
    this.db.prepare("DELETE FROM messages WHERE session_id = ?").run(sessionId);
  }
}
