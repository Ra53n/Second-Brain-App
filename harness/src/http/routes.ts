// routes.ts — CRUD чатов (за session-авторизацией, скоуп по владельцу),
// отправка/поллинг; админка по роли (логи всех пользователей + алерты).

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { ValidationError } from "../domain/errors.js";
import { requireUser, requireAdmin } from "./authMiddleware.js";
import { checkOrigin } from "./routes.auth.js";
import type { ChatMode } from "../domain/chat.js";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function uuid(params: unknown, key = "id"): string {
  const v = (params as Record<string, string>)[key] ?? "";
  if (!UUID_RE.test(v)) throw new ValidationError("Некорректный идентификатор");
  return v;
}

export function registerRoutes(app: FastifyInstance, ctx: AppContext): void {
  // ── Чаты пользователя (нужна сессия; всё скоупится по owner) ─────────────────
  app.register(async (chat) => {
    chat.addHook("preHandler", requireUser(ctx.apiToken, ctx.auth));
    const owner = (req: { principal?: { user: { id: string } | null } }): string => req.principal!.user!.id;

    chat.post("/chat/chats", async (req, reply) => {
      checkOrigin(req);
      reply.status(201);
      return ctx.manager.createChat(owner(req));
    });

    chat.get("/chat/chats", async (req) => ({ items: ctx.manager.listChats(owner(req)) }));

    chat.get("/chat/chats/:id", async (req) => ctx.manager.getChat(uuid(req.params), owner(req)));

    chat.patch("/chat/chats/:id", async (req) => {
      checkOrigin(req);
      const id = uuid(req.params);
      const body = (req.body ?? {}) as { title?: unknown; mode?: unknown };
      if (typeof body.title === "string") ctx.manager.rename(id, owner(req), body.title);
      if (body.mode === "normal" || body.mode === "loop") ctx.manager.setMode(id, owner(req), body.mode as ChatMode);
      return ctx.manager.getChat(id, owner(req)).chat;
    });

    chat.delete("/chat/chats/:id", async (req) => {
      checkOrigin(req);
      ctx.manager.deleteChat(uuid(req.params), owner(req));
      return { ok: true };
    });

    chat.post(
      "/chat/chats/:id/messages",
      { config: { rateLimit: { max: () => ctx.configView().rateLimitPerMin, timeWindow: "1 minute" } } },
      async (req, reply) => {
        checkOrigin(req);
        const id = uuid(req.params);
        const body = (req.body ?? {}) as { content?: unknown; webSearch?: unknown };
        const content = typeof body.content === "string" ? body.content : "";
        if (!content.trim()) throw new ValidationError("Пустое сообщение");
        const assistant = ctx.manager.send(id, owner(req), content, { webSearch: body.webSearch === true });
        reply.status(202);
        return { id: assistant.id, status: assistant.status };
      },
    );

    chat.get("/chat/messages/:id", async (req) => ctx.manager.getMessage(uuid(req.params), owner(req)));
  });

  // ── Админка (роль is_admin или break-glass bearer) ──────────────────────────
  app.register(async (admin) => {
    admin.addHook("preHandler", requireAdmin(ctx.apiToken, ctx.auth));

    admin.get("/chat/admin/config", async () => ctx.configView());
    admin.get("/chat/admin/users", async () => ({ items: ctx.auth.listUsers() }));
    admin.get("/chat/admin/stats", async () => ctx.manager.adminStats());
    admin.get("/chat/admin/chats", async () => ({ items: ctx.manager.adminChats() }));
    admin.get("/chat/admin/chats/:id", async (req) => ctx.manager.adminChatDetail(uuid(req.params)));
    admin.get("/chat/admin/messages", async (req) => {
      const q = (req.query ?? {}) as Record<string, unknown>;
      const alertsOnly = q.alertsOnly === "1" || q.alertsOnly === "true";
      return { items: ctx.manager.adminMessages(alertsOnly) };
    });
  });
}
