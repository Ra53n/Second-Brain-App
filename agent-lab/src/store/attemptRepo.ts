// attemptRepo.ts — журнал попыток взлома. Один обмен = одна строка.
//
// Это готовый отчёт по домашке: видно, что спрашивали, что ответил агент, какие
// инструменты дёрнул, какие флаги утекли, а какие попытки эксфильтрации срезал
// egress-guard. Пишется всегда, независимо от исхода.

import { randomUUID } from "node:crypto";
import type { DB } from "./db.js";
import type { Attempt, FlagKey, SecurityLevel } from "../domain/types.js";

export interface RecordAttemptInput {
  sessionId: string;
  securityLevel: SecurityLevel;
  userText: string;
  answerText: string;
  tools: string[];
  captured: FlagKey[];
  quoted: FlagKey[];
  exfiltrated: FlagKey[];
  blocked: string[];
  usage: unknown;
}

export interface AttemptRow extends Attempt {
  quoted: FlagKey[];
  exfiltrated: FlagKey[];
  sessionLabel: string;
}

function parseArray(raw: unknown): string[] {
  try {
    const parsed = JSON.parse(String(raw ?? "[]"));
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return [];
  }
}

export class AttemptRepo {
  constructor(
    private readonly db: DB,
    private readonly now: () => Date = () => new Date(),
  ) {}

  record(input: RecordAttemptInput): string {
    const id = randomUUID();
    this.db
      .prepare(
        `INSERT INTO attempts
           (id, session_id, created_at, security_level, user_text, answer_text,
            tools_json, captured_json, quoted_json, exfil_json, blocked_json, usage_json)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        id,
        input.sessionId,
        this.now().toISOString(),
        input.securityLevel,
        input.userText,
        input.answerText,
        JSON.stringify(input.tools),
        JSON.stringify(input.captured),
        JSON.stringify(input.quoted),
        JSON.stringify(input.exfiltrated),
        JSON.stringify(input.blocked),
        JSON.stringify(input.usage ?? {}),
      );
    return id;
  }

  /** Сколько обменов было за последние 24 часа (суточный потолок). */
  countSince(since: Date): number {
    const row = this.db
      .prepare("SELECT COUNT(*) AS n FROM attempts WHERE created_at >= ?")
      .get(since.toISOString()) as { n: number };
    return row.n;
  }

  list(limit = 200, sessionId?: string): AttemptRow[] {
    const sql = `SELECT a.*, s.label AS session_label FROM attempts a
                 LEFT JOIN lab_sessions s ON s.id = a.session_id
                 ${sessionId ? "WHERE a.session_id = ?" : ""}
                 ORDER BY a.created_at DESC LIMIT ?`;
    const rows = (
      sessionId
        ? this.db.prepare(sql).all(sessionId, limit)
        : this.db.prepare(sql).all(limit)
    ) as Array<Record<string, unknown>>;
    return rows.map((r) => ({
      id: String(r.id),
      sessionId: String(r.session_id),
      sessionLabel: String(r.session_label ?? ""),
      createdAt: String(r.created_at),
      securityLevel: String(r.security_level) as SecurityLevel,
      userText: String(r.user_text ?? ""),
      answerText: String(r.answer_text ?? ""),
      tools: parseArray(r.tools_json),
      captured: parseArray(r.captured_json) as FlagKey[],
      quoted: parseArray(r.quoted_json) as FlagKey[],
      exfiltrated: parseArray(r.exfil_json) as FlagKey[],
      blocked: parseArray(r.blocked_json),
    }));
  }

  /** Скорборд: первый захват каждого флага. */
  scoreboard(): Array<{ flag: FlagKey; at: string; sessionLabel: string; level: SecurityLevel }> {
    const rows = this.db
      .prepare(
        `SELECT a.created_at, a.captured_json, a.security_level, s.label AS session_label
         FROM attempts a LEFT JOIN lab_sessions s ON s.id = a.session_id
         WHERE a.captured_json <> '[]' ORDER BY a.created_at ASC`,
      )
      .all() as Array<Record<string, unknown>>;
    const seen = new Map<string, { flag: FlagKey; at: string; sessionLabel: string; level: SecurityLevel }>();
    for (const row of rows) {
      for (const flag of parseArray(row.captured_json) as FlagKey[]) {
        if (seen.has(flag)) continue;
        seen.set(flag, {
          flag,
          at: String(row.created_at),
          sessionLabel: String(row.session_label ?? ""),
          level: String(row.security_level) as SecurityLevel,
        });
      }
    }
    return [...seen.values()];
  }
}
