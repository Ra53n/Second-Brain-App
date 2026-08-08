// routes.ts — публичный запуск прогонов (за rate-limit) + админка по bearer.

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { ValidationError, NotFoundError } from "../domain/errors.js";
import { requireAdmin } from "./authMiddleware.js";
import { TASKS } from "../tasks.js";

interface StartBody {
  taskId?: unknown;
  prompt?: unknown;
  title?: unknown;
  secure?: unknown;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** id прогонов рождаются только из randomUUID; ранняя проверка формата —
 *  defense-in-depth от подстановки пути в Workspace(root, runId). */
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
    taskId: ctx.taskId,
    taskTitle: ctx.taskTitle,
    state: ctx.state,
    status: ctx.status,
    outcome: ctx.outcome,
    round: ctx.round,
    maxRounds: ctx.maxRounds,
    secure: ctx.secure,
    warnings: ctx.warnings,
    findings: ctx.findings,
    pwned: ctx.pwned,
    costUsd: ctx.costUsd,
    errorText: ctx.errorText,
  };
}

export function registerRoutes(app: FastifyInstance, ctx: AppContext): void {
  // ── Список встроенных задач (публично) ──────────────────────────────────────
  app.get("/harness/tasks", async () => ({
    items: TASKS.map((t) => ({ id: t.id, title: t.title, trap: t.trap })),
  }));

  // ── Запуск прогона (за rate-limit по IP) ────────────────────────────────────
  app.post(
    "/harness/runs",
    {
      config: {
        rateLimit: { max: () => ctx.configView().rateLimitPerMin, timeWindow: "1 minute" },
      },
    },
    async (req, reply) => {
      const body = (req.body ?? {}) as StartBody;
      const params = {
        taskId: typeof body.taskId === "string" ? body.taskId : undefined,
        prompt: typeof body.prompt === "string" ? body.prompt : undefined,
        title: typeof body.title === "string" ? body.title : undefined,
        secure: typeof body.secure === "boolean" ? body.secure : undefined,
      };
      if (!params.taskId && !params.prompt) {
        throw new ValidationError("Укажи taskId встроенной задачи или свой prompt");
      }
      const run = ctx.manager.start(params);
      reply.status(202);
      return { id: run.id, state: run.state, status: run.status };
    },
  );

  app.get("/harness/runs/:id", async (req) => {
    const id = runId(req.params);
    const run = publicRun(ctx.repo, id);
    return { run, steps: ctx.repo.steps(id) };
  });

  app.post("/harness/runs/:id/resume", async (req) => {
    const run = ctx.manager.resume(runId(req.params));
    return { id: run.id, state: run.state, status: run.status };
  });

  // ── Админка (bearer) ────────────────────────────────────────────────────────
  const admin = { preHandler: requireAdmin(ctx) };

  app.get("/harness/admin/config", admin, async () => ctx.configView());

  app.get("/harness/admin/runs", admin, async (req) => {
    const limit = Number((req.query as Record<string, unknown>)?.limit ?? 100);
    return { items: ctx.repo.listRuns(Number.isFinite(limit) ? limit : 100) };
  });

  app.get("/harness/admin/runs/:id/steps", admin, async (req) => {
    const id = runId(req.params);
    return { run: publicRun(ctx.repo, id), steps: ctx.repo.steps(id) };
  });
}
