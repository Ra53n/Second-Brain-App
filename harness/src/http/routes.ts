// routes.ts — CRUD чатов, отправка сообщений (за rate-limit), поллинг ответа;
// админка по bearer (журнал чатов/сообщений + настройки агента).

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { ValidationError } from "../domain/errors.js";
import { requireAdmin } from "./authMiddleware.js";
import type { ChatMode } from "../domain/chat.js";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function uuid(params: unknown, key = "id"): string {
  const v = (params as Record<string, string>)[key] ?? "";
  if (!UUID_RE.test(v)) throw new ValidationError("Некорректный идентификатор");
  return v;
}

export function registerRoutes(app: FastifyInstance, ctx: AppContext): void {
  // ── Чаты ────────────────────────────────────────────────────────────────────
  app.post("/chat/chats", async (_req, reply) => {
    reply.status(201);
    return ctx.manager.createChat();
  });

  app.get("/chat/chats", async () => ({ items: ctx.manager.listChats() }));

  app.get("/chat/chats/:id", async (req) => ctx.manager.getChat(uuid(req.params)));

  app.patch("/chat/chats/:id", async (req) => {
    const id = uuid(req.params);
    const body = (req.body ?? {}) as { title?: unknown; mode?: unknown };
    if (typeof body.title === "string") ctx.manager.rename(id, body.title);
    if (body.mode === "normal" || body.mode === "loop") ctx.manager.setMode(id, body.mode as ChatMode);
    return ctx.manager.getChat(id).chat;
  });

  app.delete("/chat/chats/:id", async (req) => {
    ctx.manager.deleteChat(uuid(req.params));
    return { ok: true };
  });

  // ── Отправка сообщения (за rate-limit по IP) ────────────────────────────────
  app.post(
    "/chat/chats/:id/messages",
    { config: { rateLimit: { max: () => ctx.configView().rateLimitPerMin, timeWindow: "1 minute" } } },
    async (req, reply) => {
      const id = uuid(req.params);
      const body = (req.body ?? {}) as { content?: unknown };
      const content = typeof body.content === "string" ? body.content : "";
      if (!content.trim()) throw new ValidationError("Пустое сообщение");
      const assistant = ctx.manager.send(id, content);
      reply.status(202);
      return { id: assistant.id, status: assistant.status };
    },
  );

  // Поллинг одного сообщения (пока pending).
  app.get("/chat/messages/:id", async (req) => ctx.manager.getMessage(uuid(req.params)));

  // ── Админка (bearer) ────────────────────────────────────────────────────────
  const admin = { preHandler: requireAdmin(ctx) };

  app.get("/chat/admin/config", admin, async () => ctx.configView());

  app.get("/chat/admin/chats", admin, async () => ({ items: ctx.manager.listChats() }));

  app.get("/chat/admin/chats/:id", admin, async (req) => ctx.manager.getChat(uuid(req.params)));
}
