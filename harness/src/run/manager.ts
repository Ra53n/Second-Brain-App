// manager.ts — владелец жизненного цикла прогонов: создание, фоновый запуск,
// resume. Держит поколение в SQLite (bumpGeneration) — устаревший воркер,
// доигрывая await, обновит 0 строк и выйдет.

import { randomUUID } from "node:crypto";
import { ValidationError, NotFoundError } from "../domain/errors.js";
import type { RunContext } from "../fsm/types.js";
import { findTask } from "../tasks.js";
import { runToCompletion, type OrchestratorDeps } from "./orchestrator.js";
import type { RunsRepo } from "../store/runsRepo.js";

export interface StartParams {
  taskId?: string;
  prompt?: string;
  title?: string;
  secure?: boolean;
}

export interface ManagerConfig {
  maxRounds: number;
  rateLimitPerMin: number;
  dailyLimit: number;
}

export class RunManager {
  private readonly inFlight = new Map<string, Promise<void>>();

  constructor(
    private readonly deps: OrchestratorDeps,
    private readonly cfg: ManagerConfig,
    private readonly now: () => Date = () => new Date(),
  ) {}

  private get repo(): RunsRepo {
    return this.deps.repo;
  }

  /** На старте сервиса: зависшие running → paused (их можно resume). */
  recoverOnBoot(): number {
    return this.repo.pauseRunning();
  }

  start(params: StartParams): RunContext {
    const since = new Date(this.now().getTime() - 24 * 3600 * 1000).toISOString();
    if (this.repo.runsSince(since) >= this.cfg.dailyLimit) {
      throw new ValidationError("Суточный лимит прогонов исчерпан. Попробуй завтра.");
    }

    let taskId = "custom";
    let title = params.title?.trim() || "Свой промпт";
    let prompt = params.prompt?.trim() ?? "";

    if (params.taskId) {
      const task = findTask(params.taskId);
      if (!task) throw new ValidationError(`Нет задачи с id ${params.taskId}`);
      taskId = task.id;
      title = task.title;
      prompt = task.prompt;
    }
    if (!prompt) throw new ValidationError("Пустой промпт задачи");

    const ctx: RunContext = {
      id: randomUUID(),
      taskId,
      taskTitle: title,
      taskPrompt: prompt,
      secure: params.secure ?? true,
      state: "generating",
      status: "running",
      round: 1,
      maxRounds: this.cfg.maxRounds,
      code: "",
      buildErrors: "",
      findings: [],
      warnings: [],
      feedback: "",
      outcome: null,
      errorText: null,
      pwned: false,
      costUsd: 0,
      startedAt: this.now().toISOString(),
    };
    this.repo.insert(ctx);
    this.spawn(ctx.id);
    return ctx;
  }

  resume(runId: string): RunContext {
    const ctx = this.repo.load(runId);
    if (!ctx) throw new NotFoundError("Прогон не найден");
    if (ctx.status !== "paused" && ctx.status !== "failed") {
      throw new ValidationError(`Прогон в статусе ${ctx.status} — resume не нужен`);
    }
    const resumed: RunContext = { ...ctx, status: "running", errorText: null };
    // Пишем под текущим поколением, затем спавним под новым.
    this.repo.save(resumed, this.repo.generationOf(runId));
    this.spawn(runId);
    return resumed;
  }

  private spawn(runId: string): void {
    const generation = this.repo.bumpGeneration(runId);
    const promise = runToCompletion(this.deps, runId, generation).finally(() => {
      if (this.inFlight.get(runId) === promise) this.inFlight.delete(runId);
    });
    this.inFlight.set(runId, promise);
  }

  /** Для тестов и graceful-выключения: дождаться завершения прогона. */
  async wait(runId: string): Promise<void> {
    await this.inFlight.get(runId);
  }
}
