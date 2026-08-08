// runsRepo.ts — персистентность прогонов FSM и журнала фаз.
//
// Ключевое из паттерна приложения:
//  - контекст пишется целиком после каждой фазы;
//  - гонки закрыты поколением: UPDATE … WHERE id=? AND generation=? (устаревший
//    воркер обновит 0 строк и выйдет);
//  - снисходительный декодер: битый/старый JSON → дефолты, неизвестный enum →
//    безопасное значение (generating/paused);
//  - на старте сервиса зависшие running → paused (resume-able).

import type { DB } from "./db.js";
import type { Finding, RunContext, RunState, RunStatus } from "../fsm/types.js";
import { ALL_STATES } from "../fsm/types.js";

export interface StepRow {
  runId: string;
  round: number;
  phase: string;
  display: string;
  promptPreview: string;
  answerPreview: string;
  findings: Finding[];
  gateway: Record<string, unknown>;
  egress: string[];
  pwned: boolean;
  costUsd: number;
}

const VALID_STATUS = new Set<RunStatus>(["running", "paused", "failed", "finished"]);

function coerceState(v: unknown): RunState {
  return ALL_STATES.includes(v as RunState) ? (v as RunState) : "generating";
}

function coerceStatus(v: unknown): RunStatus {
  return VALID_STATUS.has(v as RunStatus) ? (v as RunStatus) : "paused";
}

export class RunsRepo {
  constructor(
    private readonly db: DB,
    private readonly now: () => Date = () => new Date(),
  ) {}

  /**
   * На старте сервиса: зависшие running → paused. Возвращает число поднятых.
   * json_set обязателен: load() читает статус из ctx_json, обновление одной
   * колонки оставило бы декодированный контекст в running и сломало resume.
   */
  pauseRunning(): number {
    const ts = this.now().toISOString();
    const info = this.db
      .prepare(
        "UPDATE runs SET status='paused', ctx_json=json_set(ctx_json,'$.status','paused'), updated_at=? WHERE status='running'",
      )
      .run(ts);
    return info.changes;
  }

  insert(ctx: RunContext): void {
    const ts = this.now().toISOString();
    this.db
      .prepare(
        `INSERT INTO runs (id, created_at, updated_at, task_id, task_title, state, status,
           outcome, round, secure, pwned, cost_usd, generation, ctx_json)
         VALUES (@id, @ts, @ts, @taskId, @taskTitle, @state, @status, @outcome, @round,
           @secure, @pwned, @cost, 0, @ctx)`,
      )
      .run({
        id: ctx.id,
        ts,
        taskId: ctx.taskId,
        taskTitle: ctx.taskTitle,
        state: ctx.state,
        status: ctx.status,
        outcome: ctx.outcome ?? "",
        round: ctx.round,
        secure: ctx.secure ? 1 : 0,
        pwned: ctx.pwned ? 1 : 0,
        cost: ctx.costUsd,
        ctx: JSON.stringify(ctx),
      });
  }

  /**
   * Пишет контекст под своим поколением. Возвращает false, если поколение
   * устарело (прогон сброшен/перезапущен) — воркер должен молча выйти.
   */
  save(ctx: RunContext, generation: number): boolean {
    const ts = this.now().toISOString();
    const info = this.db
      .prepare(
        `UPDATE runs SET updated_at=@ts, state=@state, status=@status, outcome=@outcome,
           round=@round, secure=@secure, pwned=@pwned, cost_usd=@cost, ctx_json=@ctx
         WHERE id=@id AND generation=@gen`,
      )
      .run({
        ts,
        state: ctx.state,
        status: ctx.status,
        outcome: ctx.outcome ?? "",
        round: ctx.round,
        secure: ctx.secure ? 1 : 0,
        pwned: ctx.pwned ? 1 : 0,
        cost: ctx.costUsd,
        ctx: JSON.stringify(ctx),
        id: ctx.id,
        gen: generation,
      });
    return info.changes > 0;
  }

  /** Инкремент поколения (при resume/reset). Возвращает новое значение. */
  bumpGeneration(id: string): number {
    this.db.prepare("UPDATE runs SET generation = generation + 1 WHERE id=?").run(id);
    const row = this.db.prepare("SELECT generation FROM runs WHERE id=?").get(id) as
      | { generation: number }
      | undefined;
    return row?.generation ?? 0;
  }

  generationOf(id: string): number {
    const row = this.db.prepare("SELECT generation FROM runs WHERE id=?").get(id) as
      | { generation: number }
      | undefined;
    return row?.generation ?? 0;
  }

  load(id: string): RunContext | null {
    const row = this.db.prepare("SELECT ctx_json FROM runs WHERE id=?").get(id) as
      | { ctx_json: string }
      | undefined;
    if (!row) return null;
    return this.decode(row.ctx_json);
  }

  /** Снисходительный декодер: любое отсутствующее/битое поле → безопасный дефолт. */
  private decode(json: string): RunContext {
    let raw: Record<string, unknown> = {};
    try {
      const parsed = JSON.parse(json);
      if (parsed && typeof parsed === "object") raw = parsed as Record<string, unknown>;
    } catch {
      raw = {};
    }
    const str = (k: string, d = ""): string => (typeof raw[k] === "string" ? (raw[k] as string) : d);
    const num = (k: string, d: number): number =>
      typeof raw[k] === "number" && Number.isFinite(raw[k] as number) ? (raw[k] as number) : d;
    const bool = (k: string, d: boolean): boolean => (typeof raw[k] === "boolean" ? (raw[k] as boolean) : d);
    const arr = <T>(k: string): T[] => (Array.isArray(raw[k]) ? (raw[k] as T[]) : []);

    const outcomeRaw = raw.outcome;
    return {
      id: str("id"),
      taskId: str("taskId"),
      taskTitle: str("taskTitle"),
      taskPrompt: str("taskPrompt"),
      secure: bool("secure", true),
      state: coerceState(raw.state),
      status: coerceStatus(raw.status),
      round: num("round", 1),
      maxRounds: num("maxRounds", 4),
      code: str("code"),
      buildErrors: str("buildErrors"),
      findings: arr<Finding>("findings"),
      warnings: arr<string>("warnings"),
      feedback: str("feedback"),
      outcome: typeof outcomeRaw === "string" && outcomeRaw ? (outcomeRaw as RunContext["outcome"]) : null,
      errorText: typeof raw.errorText === "string" ? (raw.errorText as string) : null,
      pwned: bool("pwned", false),
      costUsd: num("costUsd", 0),
      startedAt: str("startedAt"),
    };
  }

  addStep(step: StepRow): void {
    this.db
      .prepare(
        `INSERT INTO steps (run_id, created_at, round, phase, display, prompt_preview,
           answer_preview, findings_json, gateway_json, egress_json, pwned, cost_usd)
         VALUES (@runId, @ts, @round, @phase, @display, @promptPreview, @answerPreview,
           @findings, @gateway, @egress, @pwned, @cost)`,
      )
      .run({
        runId: step.runId,
        ts: this.now().toISOString(),
        round: step.round,
        phase: step.phase,
        display: step.display,
        promptPreview: step.promptPreview,
        answerPreview: step.answerPreview,
        findings: JSON.stringify(step.findings),
        gateway: JSON.stringify(step.gateway),
        egress: JSON.stringify(step.egress),
        pwned: step.pwned ? 1 : 0,
        cost: step.costUsd,
      });
  }

  listRuns(limit = 100): Array<Record<string, unknown>> {
    return this.db
      .prepare(
        `SELECT id, created_at, updated_at, task_id, task_title, state, status, outcome,
           round, secure, pwned, cost_usd FROM runs ORDER BY created_at DESC LIMIT ?`,
      )
      .all(limit) as Array<Record<string, unknown>>;
  }

  steps(runId: string): Array<Record<string, unknown>> {
    return this.db
      .prepare("SELECT * FROM steps WHERE run_id=? ORDER BY id ASC")
      .all(runId) as Array<Record<string, unknown>>;
  }

  runsSince(sinceIso: string): number {
    const row = this.db.prepare("SELECT COUNT(*) AS n FROM runs WHERE created_at >= ?").get(sinceIso) as {
      n: number;
    };
    return row.n;
  }
}
