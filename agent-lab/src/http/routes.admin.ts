// routes.admin.ts — админка владельца: настройки, флаги, журнал попыток, скорборд.
//
// Всё под admin bearer-токеном. Секреты наружу не отдаются: только признак
// «задан» и последние 4 символа (см. settingsRepo.toPublic).

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { requireAdmin } from "./authMiddleware.js";
import { ValidationError } from "../domain/errors.js";
import { toPublic } from "../store/settingsRepo.js";
import { hashPassword } from "../auth/passwords.js";
import { parseSecurityLevel, type LabSettings } from "../domain/types.js";

const settingsBody = {
  type: "object",
  properties: {
    llmUrl: { type: "string", maxLength: 300 },
    llmApiKey: { type: "string", maxLength: 300 },
    model: { type: "string", maxLength: 120 },
    temperature: { type: "number", minimum: 0, maximum: 2 },
    maxTokens: { type: "integer", minimum: 128, maximum: 8000 },
    maxIterations: { type: "integer", minimum: 1, maximum: 10 },
    securityLevel: { type: "string" },
    searchProvider: { type: "string" },
    searchApiKey: { type: "string", maxLength: 300 },
    accessCode: { type: "string", maxLength: 200 },
    dailyExchangeLimit: { type: "integer", minimum: 1, maximum: 100000 },
  },
} as const;

export function registerAdminRoutes(app: FastifyInstance, ctx: AppContext): void {
  const guard = { preHandler: requireAdmin(ctx) };

  app.get("/lab/admin/settings", guard, async () => ({
    settings: toPublic(ctx.settingsRepo.get()),
  }));

  app.put<{ Body: Record<string, unknown> }>(
    "/lab/admin/settings",
    { ...guard, schema: { body: settingsBody } },
    async (req) => {
      const body = req.body;
      const patch: Partial<LabSettings> = {};
      const copyString = (key: keyof LabSettings) => {
        const value = body[key as string];
        // Пустая строка не затирает сохранённый секрет — так поле «ключ» можно
        // оставить пустым в форме, не потеряв уже заданное значение.
        if (typeof value === "string" && value.trim()) (patch as Record<string, unknown>)[key] = value.trim();
      };
      copyString("llmUrl");
      copyString("llmApiKey");
      copyString("model");
      copyString("searchApiKey");
      for (const key of ["temperature", "maxTokens", "maxIterations", "dailyExchangeLimit"] as const) {
        if (typeof body[key] === "number") (patch as Record<string, unknown>)[key] = body[key];
      }
      if (typeof body.securityLevel === "string") {
        patch.securityLevel = parseSecurityLevel(body.securityLevel);
      }
      if (typeof body.searchProvider === "string") {
        const provider = body.searchProvider;
        if (!["none", "tavily", "brave", "serper"].includes(provider)) {
          throw new ValidationError(`Неизвестный провайдер поиска: ${provider}`);
        }
        patch.searchProvider = provider as LabSettings["searchProvider"];
      }
      if (typeof body.accessCode === "string" && body.accessCode.trim()) {
        patch.accessCodeHash = await hashPassword(body.accessCode.trim());
      }
      return { settings: toPublic(ctx.settingsRepo.update(patch)) };
    },
  );

  app.get("/lab/admin/flags", guard, async () => ({ flags: ctx.flagsRepo.list() }));

  app.post("/lab/admin/flags/rotate", guard, async () => ({ flags: ctx.flagsRepo.rotate() }));

  app.get<{ Querystring: { session?: string; limit?: number } }>(
    "/lab/admin/attempts",
    guard,
    async (req) => ({
      attempts: ctx.attemptRepo.list(
        Math.min(Number(req.query.limit) || 200, 1000),
        req.query.session,
      ),
    }),
  );

  app.get("/lab/admin/sessions", guard, async () => ({ sessions: ctx.sessionRepo.list() }));

  app.get("/lab/admin/scoreboard", guard, async () => ({
    scoreboard: ctx.attemptRepo.scoreboard(),
    flags: ctx.flagsRepo.list().map((f) => f.key),
  }));
}
