// auditRepo.ts — журнал запросов через gateway (таблица requests).
//
// Каждый запрос = одна строка: находки input guard, вердикт output guard,
// токены и стоимость. Сырые секреты не пишем — только маскированный превью и
// компактные записи находок (тип/подтип/кодировка).

import { randomUUID } from "node:crypto";
import type { DB } from "./db.js";
import type { FindingRecord, InputAction, RequestRecord } from "../domain/types.js";
import type { OutputIssue, OutputVerdict } from "../guard/outputGuard.js";

export interface LogInput {
  ip: string;
  userPreview: string;
  inputFindings: FindingRecord[];
  inputAction: InputAction;
  answer: string;
  outputVerdict: OutputVerdict;
  outputIssues: OutputIssue[];
  model: string;
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  costUsd: number;
  blocked: boolean;
}

export interface AuditStats {
  total: number;
  blocked: number;
  intercepted: number;
  totalTokens: number;
  totalCostUsd: number;
}

function rowToRecord(row: Record<string, unknown>): RequestRecord {
  return {
    id: String(row.id),
    createdAt: String(row.created_at),
    ip: String(row.ip ?? ""),
    userPreview: String(row.user_preview ?? ""),
    inputFindings: safeParse<FindingRecord[]>(row.input_findings_json, []),
    inputAction: String(row.input_action ?? "allow") as InputAction,
    answer: String(row.answer ?? ""),
    outputVerdict: String(row.output_verdict ?? "pass") as OutputVerdict,
    outputIssues: safeParse<OutputIssue[]>(row.output_issues_json, []),
    model: String(row.model ?? ""),
    promptTokens: Number(row.prompt_tokens ?? 0),
    completionTokens: Number(row.completion_tokens ?? 0),
    totalTokens: Number(row.total_tokens ?? 0),
    costUsd: Number(row.cost_usd ?? 0),
    blocked: Number(row.blocked ?? 0) === 1,
  };
}

function safeParse<T>(raw: unknown, fallback: T): T {
  if (typeof raw !== "string") return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

export class AuditRepo {
  constructor(
    private readonly db: DB,
    private readonly now: () => Date = () => new Date(),
    private readonly genId: () => string = randomUUID,
  ) {}

  log(input: LogInput): RequestRecord {
    const record: RequestRecord = { id: this.genId(), createdAt: this.now().toISOString(), ...input };
    this.db
      .prepare(
        `INSERT INTO requests (id, created_at, ip, user_preview, input_findings_json,
           input_action, answer, output_verdict, output_issues_json, model,
           prompt_tokens, completion_tokens, total_tokens, cost_usd, blocked)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        record.id,
        record.createdAt,
        record.ip,
        record.userPreview,
        JSON.stringify(record.inputFindings),
        record.inputAction,
        record.answer,
        record.outputVerdict,
        JSON.stringify(record.outputIssues),
        record.model,
        record.promptTokens,
        record.completionTokens,
        record.totalTokens,
        record.costUsd,
        record.blocked ? 1 : 0,
      );
    return record;
  }

  list(limit = 100): RequestRecord[] {
    const rows = this.db
      .prepare("SELECT * FROM requests ORDER BY created_at DESC LIMIT ?")
      .all(Math.max(1, Math.min(1000, limit))) as Record<string, unknown>[];
    return rows.map(rowToRecord);
  }

  /** Только перехваты: input замаскирован/заблокирован или output не pass. */
  interceptions(limit = 100): RequestRecord[] {
    const rows = this.db
      .prepare(
        `SELECT * FROM requests
         WHERE input_action != 'allow' OR output_verdict != 'pass'
         ORDER BY created_at DESC LIMIT ?`,
      )
      .all(Math.max(1, Math.min(1000, limit))) as Record<string, unknown>[];
    return rows.map(rowToRecord);
  }

  countSince(iso: string): number {
    const row = this.db
      .prepare("SELECT COUNT(*) AS n FROM requests WHERE created_at >= ?")
      .get(iso) as { n: number };
    return row.n;
  }

  stats(): AuditStats {
    const row = this.db
      .prepare(
        `SELECT COUNT(*) AS total,
                SUM(blocked) AS blocked,
                SUM(CASE WHEN input_action != 'allow' OR output_verdict != 'pass' THEN 1 ELSE 0 END) AS intercepted,
                SUM(total_tokens) AS tokens,
                SUM(cost_usd) AS cost
         FROM requests`,
      )
      .get() as Record<string, number | null>;
    return {
      total: row.total ?? 0,
      blocked: row.blocked ?? 0,
      intercepted: row.intercepted ?? 0,
      totalTokens: row.tokens ?? 0,
      totalCostUsd: row.cost ?? 0,
    };
  }
}
