// routes.chat.ts — вход по коду доступа и сам чат.

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { requireSession, SESSION_COOKIE } from "./authMiddleware.js";
import { UnauthorizedError, ValidationError } from "../domain/errors.js";
import { verifyPassword } from "../auth/passwords.js";

const MAX_MESSAGE_CHARS = 8000;
const SESSION_COOKIE_MAX_AGE = 14 * 24 * 60 * 60;

const enterBody = {
  type: "object",
  required: ["code"],
  properties: {
    code: { type: "string", minLength: 1, maxLength: 200 },
    label: { type: "string", maxLength: 60 },
  },
} as const;

const messageBody = {
  type: "object",
  required: ["text"],
  properties: { text: { type: "string", minLength: 1, maxLength: MAX_MESSAGE_CHARS } },
} as const;

export function registerChatRoutes(app: FastifyInstance, ctx: AppContext): void {
  // Вход по коду доступа. Rate-limit жёсткий: код короткий, перебор дешёвый.
  app.post<{ Body: { code: string; label?: string } }>(
    "/lab/enter",
    {
      schema: { body: enterBody },
      config: { rateLimit: { max: 10, timeWindow: "5 minutes" } },
    },
    async (req, reply) => {
      const settings = ctx.settingsRepo.get();
      if (!settings.accessCodeHash) {
        throw new UnauthorizedError("Код доступа не настроен — обратись к владельцу лаборатории");
      }
      const ok = await verifyPassword(req.body.code, settings.accessCodeHash);
      if (!ok) throw new UnauthorizedError("Неверный код доступа");

      const { session, token } = ctx.sessionRepo.create(req.body.label ?? "аноним");
      reply.setCookie(SESSION_COOKIE, token, {
        httpOnly: true,
        sameSite: "lax",
        secure: (req.headers["x-forwarded-proto"] ?? req.protocol) === "https",
        path: "/lab",
        maxAge: SESSION_COOKIE_MAX_AGE,
      });
      return { session: { id: session.id, label: session.label } };
    },
  );

  app.get("/lab/me", { preHandler: requireSession(ctx) }, async (req) => ({
    session: { id: req.labSession!.id, label: req.labSession!.label },
    history: ctx.sessionRepo.history(req.labSession!.id),
  }));

  app.post<{ Body: { text: string } }>(
    "/lab/message",
    {
      schema: { body: messageBody },
      preHandler: requireSession(ctx),
      config: { rateLimit: { max: 20, timeWindow: "5 minutes" } },
    },
    async (req) => {
      const text = req.body.text.trim();
      if (!text) throw new ValidationError("Пустое сообщение");
      const result = await ctx.chat.answer(req.labSession!, text);
      // Атакующему отдаём только ответ и имена инструментов: список срезанного
      // egress-guard'ом — это подсказка, она остаётся владельцу в журнале.
      return { answer: result.answer, tools: result.tools, usage: result.usage };
    },
  );

  app.post("/lab/reset", { preHandler: requireSession(ctx) }, async (req) => {
    ctx.sessionRepo.clear(req.labSession!.id);
    return { ok: true };
  });
}
