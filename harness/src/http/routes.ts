// routes.ts — публичный запуск прогонов чата (за rate-limit) + админка по bearer.

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { ValidationError, NotFoundError } from "../domain/errors.js";
import { requireAdmin } from "./authMiddleware.js";

interface StartBody {
  prompt?: unknown;
  secure?: unknown;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** id прогонов рождаются только из randomUUID; ранняя проверка формата. */
function runId(params: unknown): string {
  const id = (params as { id?: string }).id ?? "";
  if (!UUID_RE.test(id)) throw new ValidationError("Некорректный id прогона");
  return id;
}

function publicRun(repo: AppContext["repo"], id: string): Record<string, unknown> {
  const ctx = repo.load(id);
  if (!ctx) throw new NotFoundError("Прогон не найден");
  return {
    id: ctx.id,
    taskPrompt: ctx.taskPrompt,
    state: ctx.state,
    status: ctx.status,
    outcome: ctx.outcome,
    round: ctx.round,
    maxRounds: ctx.maxRounds,
    secure: ctx.secure,
    result: ctx.status === "finished" && ctx.outcome === "done" ? ctx.result : "",
    correctness: ctx.correctness,
    findings: ctx.findings,
    warnings: ctx.warnings,
    pwned: ctx.pwned,
    costUsd: ctx.costUsd,
    errorText: ctx.errorText,
  };
}

export function registerRoutes(app: FastifyInstance, ctx: AppContext): void {
  // ── Запуск прогона (за rate-limit по IP) ────────────────────────────────────
  app.post(
    "/chat/runs",
    { config: { rateLimit: { max: () => ctx.configView().rateLimitPerMin, timeWindow: "1 minute" } } },
    async (req, reply) => {
      const body = (req.body ?? {}) as StartBody;
      const prompt = typeof body.prompt === "string" ? body.prompt : "";
      if (!prompt.trim()) throw new ValidationError("Пустой промпт");
      const run = ctx.manager.start({
        prompt,
        secure: typeof body.secure === "boolean" ? body.secure : undefined,
      });
      reply.status(202);
      return { id: run.id, state: run.state, status: run.status };
    },
  );

  app.get("/chat/runs/:id", async (req) => {
    const id = runId(req.params);
    return { run: publicRun(ctx.repo, id), steps: ctx.repo.steps(id) };
  });

  app.post("/chat/runs/:id/resume", async (req) => {
    const run = ctx.manager.resume(runId(req.params));
    return { id: run.id, state: run.state, status: run.status };
  });

  // ── Админка (bearer) ────────────────────────────────────────────────────────
  const admin = { preHandler: requireAdmin(ctx) };

  app.get("/chat/admin/config", admin, async () => ctx.configView());

  app.get("/chat/admin/runs", admin, async (req) => {
    const limit = Number((req.query as Record<string, unknown>)?.limit ?? 100);
    return { items: ctx.repo.listRuns(Number.isFinite(limit) ? limit : 100) };
  });

  app.get("/chat/admin/runs/:id/steps", admin, async (req) => {
    const id = runId(req.params);
    return { run: publicRun(ctx.repo, id), steps: ctx.repo.steps(id) };
  });
}
