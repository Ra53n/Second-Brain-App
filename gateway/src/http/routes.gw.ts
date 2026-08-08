// routes.gw.ts — публичный чат (за rate-limit по IP) + админка по bearer-токену.

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { ValidationError } from "../domain/errors.js";
import { requireAdmin } from "./authMiddleware.js";
import { toPublic } from "../store/settingsRepo.js";
import type { GatewaySettings } from "../domain/types.js";
import type { PolicyMode } from "../guard/inputGuard.js";
import type { TokenPrices } from "../cost/pricing.js";

interface ChatBody {
  prompt?: unknown;
  message?: unknown;
}

function parsePrices(raw: unknown): Record<string, TokenPrices> | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const out: Record<string, TokenPrices> = {};
  for (const [model, p] of Object.entries(raw as Record<string, any>)) {
    const inp = Number(p?.inputPerMillion);
    const outp = Number(p?.outputPerMillion);
    if (Number.isFinite(inp) && Number.isFinite(outp)) {
      out[model] = { inputPerMillion: inp, outputPerMillion: outp };
    }
  }
  return Object.keys(out).length ? out : undefined;
}

function buildPatch(body: Record<string, unknown>): Partial<GatewaySettings> {
  const patch: Partial<GatewaySettings> = {};
  if (typeof body.llmUrl === "string") patch.llmUrl = body.llmUrl.trim();
  if (typeof body.llmApiKey === "string" && body.llmApiKey.trim()) patch.llmApiKey = body.llmApiKey.trim();
  if (typeof body.model === "string") patch.model = body.model.trim();
  if (Number.isFinite(Number(body.temperature))) patch.temperature = Number(body.temperature);
  if (Number.isFinite(Number(body.maxTokens))) patch.maxTokens = Math.trunc(Number(body.maxTokens));
  if (typeof body.systemPrompt === "string") patch.systemPrompt = body.systemPrompt;
  if (body.inputPolicy === "block" || body.inputPolicy === "mask") patch.inputPolicy = body.inputPolicy as PolicyMode;
  const prices = parsePrices(body.prices);
  if (prices) patch.prices = prices;
  if (Number.isFinite(Number(body.rateLimitPerMin))) patch.rateLimitPerMin = Math.max(1, Math.trunc(Number(body.rateLimitPerMin)));
  if (Number.isFinite(Number(body.dailyLimit))) patch.dailyLimit = Math.max(1, Math.trunc(Number(body.dailyLimit)));
  return patch;
}

export function registerGatewayRoutes(app: FastifyInstance, ctx: AppContext): void {
  // ── Публичный чат: rate-limit по IP, лимит берётся из настроек ──────────────
  app.post(
    "/gw/chat",
    {
      config: {
        rateLimit: {
          // Плагин не awaited'ит max — читаем настройки синхронно.
          max: () => ctx.settingsRepo.get().rateLimitPerMin,
          timeWindow: "1 minute",
        },
      },
    },
    async (req) => {
      const body = (req.body ?? {}) as ChatBody;
      const raw = typeof body.prompt === "string" ? body.prompt : typeof body.message === "string" ? body.message : "";
      if (!raw.trim()) throw new ValidationError("Пустой промпт");

      const result = await ctx.gateway.chat({ prompt: raw, ip: req.ip });
      return {
        answer: result.answer,
        blocked: result.blocked,
        warning: result.warning ?? null,
        meta: {
          inputAction: result.inputAction,
          outputVerdict: result.outputVerdict,
          outputIssues: result.outputIssues,
          findings: result.findings,
          model: result.model,
          usage: result.usage,
          costUsd: result.costUsd,
        },
      };
    },
  );

  // ── Админка (bearer-токен) ──────────────────────────────────────────────────
  const admin = { preHandler: requireAdmin(ctx) };

  app.get("/gw/admin/settings", admin, async () => toPublic(ctx.settingsRepo.get()));

  app.put("/gw/admin/settings", admin, async (req) => {
    const patch = buildPatch((req.body ?? {}) as Record<string, unknown>);
    return toPublic(ctx.settingsRepo.update(patch));
  });

  app.get("/gw/admin/audit", admin, async (req) => {
    const limit = Number((req.query as Record<string, unknown>)?.limit ?? 100);
    return { items: ctx.auditRepo.list(Number.isFinite(limit) ? limit : 100) };
  });

  app.get("/gw/admin/interceptions", admin, async (req) => {
    const limit = Number((req.query as Record<string, unknown>)?.limit ?? 100);
    return { items: ctx.auditRepo.interceptions(Number.isFinite(limit) ? limit : 100) };
  });

  app.get("/gw/admin/stats", admin, async () => ctx.auditRepo.stats());
}
