// routes.chat.ts — HTTP-слой чата поддержки (порт routes.chat2.ts MA, без
// guest-режима: чат только после логина — «минимальная авторизация, чтобы
// различать пользователей»). Стриминг — SSE с heartbeat; события:
// status / token / done / error.

import { randomUUID } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { AppContext } from "./context.js";
import { AppError, NotFoundError, ValidationError } from "../domain/errors.js";
import { requireUserOrAdmin, ownerScope } from "./authMiddleware.js";
import type { AnswerResult, HistoryMessage } from "../chat/supportChatService.js";
import { createChatBody, feedbackBody, guestChatBody, sendChatMessageBody } from "./schemas.js";
import { SESSION_COOKIE } from "./authMiddleware.js";
import { applyFeedback } from "../crm/feedback.js";
import type { PublicUser } from "../store/usersRepo.js";

const HEARTBEAT_MS = 15_000;

function autoTitle(content: string): string {
  const oneLine = content.replace(/\s+/g, " ").trim();
  return oneLine.length <= 48 ? oneLine : oneLine.slice(0, 47) + "…";
}

/**
 * Отдача результата: SSE (стрим) или JSON. При SSE «нормальные» ошибки
 * (валидация/404) должны быть брошены ДО hijack.
 */
async function respond(
  ctx: AppContext,
  req: FastifyRequest,
  reply: FastifyReply,
  stream: boolean,
  run: (opts: {
    onDelta?: (t: string) => void;
    onStatus?: (s: string) => void;
    signal?: AbortSignal;
  }) => Promise<AnswerResult>,
  finalize: (res: AnswerResult) => Record<string, unknown>,
): Promise<unknown> {
  if (!stream) {
    const res = await run({});
    return finalize(res);
  }

  reply.hijack();
  const raw = reply.raw;
  raw.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
    "x-accel-buffering": "no",
  });
  const heartbeat = setInterval(() => raw.write(": ping\n\n"), HEARTBEAT_MS);
  const ac = new AbortController();
  req.raw.on("close", () => ac.abort());

  try {
    const res = await run({
      signal: ac.signal,
      onDelta: (t) => raw.write(`event: token\ndata: ${JSON.stringify({ delta: t })}\n\n`),
      onStatus: (s) => raw.write(`event: status\ndata: ${JSON.stringify({ status: s })}\n\n`),
    });
    const done = finalize(res);
    raw.write(`event: done\ndata: ${JSON.stringify(done)}\n\n`);
  } catch (e) {
    const err =
      e instanceof AppError
        ? { code: e.code, message: e.message }
        : { code: "internal", message: (e as Error).message };
    raw.write(`event: error\ndata: ${JSON.stringify({ error: err })}\n\n`);
  } finally {
    clearInterval(heartbeat);
    raw.end();
  }
  return reply;
}

/**
 * Гостевой чат — ПУБЛИЧНО, без аккаунта: историю присылает клиент (браузер
 * хранит её у себя), сервер ничего не пишет. Без CRM-контекста (нет email),
 * но с RAG. Rate-limit обязателен: публичный эндпоинт к тяжёлой модели;
 * от перегрузки дополнительно защищает FifoGate (429 при полной очереди).
 */
export function registerGuestChatRoutes(app: FastifyInstance, ctx: AppContext): void {
  // Здоровье LLM/очереди — публично: строка статуса в SPA видна и гостю.
  app.get("/support/llm/health", async () => {
    const queue = ctx.chat.queueStats();
    const settings = ctx.settings.getPublic();
    try {
      const [version, loaded] = await Promise.all([ctx.ollama.version(), ctx.ollama.ps()]);
      return { reachable: true, version, loaded, queue, provider: settings.provider };
    } catch {
      return { reachable: false, version: "", loaded: [], queue, provider: settings.provider };
    }
  });

  // Фидбек «решено/не решено» — публично (гость), но понимает cookie-сессию.
  // Каждая отметка фиксируется в CRM оформленным обращением (см. crm/feedback.ts).
  app.post<{
    Body: {
      resolved: boolean;
      chatId?: string;
      email?: string;
      name?: string;
      comment?: string;
      messages?: HistoryMessage[];
    };
  }>(
    "/support/feedback",
    {
      schema: { body: feedbackBody },
      config: { rateLimit: { max: 10, timeWindow: "1 minute" } },
    },
    async (req) => {
      // Опциональная cookie-сессия (без 401 — гостю тоже можно).
      let user: PublicUser | null = null;
      const signed = req.cookies?.[SESSION_COOKIE];
      if (signed) {
        const unsigned = req.unsignCookie(signed);
        if (unsigned.valid && unsigned.value) user = ctx.auth.resolveSession(unsigned.value);
      }

      const b = req.body;
      let history: HistoryMessage[];
      let email: string;
      let name: string;
      let ticketId: string | null = null;
      let chatId: string | null = null;

      if (user && b.chatId) {
        const session = ctx.chatRepo.getSession(b.chatId, user.id);
        if (!session) throw new NotFoundError("Чат не найден.");
        chatId = session.id;
        ticketId = session.ticketId || null;
        history = ctx.chatRepo
          .listMessages(session.id)
          .map((m) => ({ role: m.role, content: m.content }));
        email = user.email || (b.email ?? "").trim();
        name = user.username;
        if (!email) {
          throw new ValidationError(
            "У аккаунта нет email — укажите email, чтобы поддержка могла ответить.",
          );
        }
      } else {
        history = (b.messages ?? []).map((m) => ({ role: m.role, content: m.content }));
        email = (b.email ?? "").trim();
        name = (b.name ?? "").trim();
        if (history.length === 0) throw new ValidationError("Пустая история диалога.");
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
          // Гость отметил «решено», email не оставил — не заставляем: отметка
          // принята, но обращение в CRM не создаётся (не к кому привязать).
          if (b.resolved) return { ticketId: null, status: null, created: false };
          throw new ValidationError("Укажите корректный email, чтобы поддержка могла ответить.");
        }
      }

      const outcome = applyFeedback(ctx.crm, {
        resolved: b.resolved,
        email,
        name,
        ticketId,
        history,
        comment: (b.comment ?? "").trim(),
        at: ctx.now().toISOString(),
      });
      if (chatId && outcome.created) ctx.chatRepo.setTicketId(chatId, outcome.ticket.id);
      return {
        ticketId: outcome.ticket.id,
        status: outcome.ticket.status,
        created: outcome.created,
      };
    },
  );

  app.post<{ Body: { messages: HistoryMessage[]; stream?: boolean } }>(
    "/support/guest/chat",
    {
      schema: { body: guestChatBody },
      config: { rateLimit: { max: 12, timeWindow: "1 minute" } },
    },
    async (req, reply) => {
      const history = (req.body.messages ?? []).map((m) => ({
        role: m.role,
        content: m.content,
      }));
      if (history.length === 0) throw new ValidationError("Пустой список сообщений.");
      return respond(
        ctx,
        req,
        reply,
        req.body.stream === true,
        (opts) => ctx.chat.answer({ history, userEmail: null, ...opts }),
        (res) => ({
          message: { role: "assistant", content: res.content },
          usage: res.usage,
          timings: res.timings,
          toolCalls: res.toolCalls,
          sources: res.sources,
          droppedCount: res.droppedCount,
        }),
      );
    },
  );
}

export function registerChatRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.register(async (instance) => {
    instance.addHook("preHandler", requireUserOrAdmin(ctx.apiToken, ctx.auth));

    // ── Персистентные чаты ────────────────────────────────────────────────────
    instance.post<{ Body: { title?: string } }>(
      "/support/chats",
      { schema: { body: createChatBody } },
      async (req, reply) => {
        const now = ctx.now().toISOString();
        const session = ctx.chatRepo.createSession({
          id: randomUUID(),
          userId: ownerScope(req.principal!),
          title: req.body?.title ?? "",
          ticketId: "",
          createdAt: now,
          updatedAt: now,
        });
        reply.status(201);
        return session;
      },
    );

    instance.get("/support/chats", async (req) => ({
      items: ctx.chatRepo.listSessions(ownerScope(req.principal!), 50),
    }));

    instance.get<{ Params: { id: string } }>("/support/chats/:id", async (req) => {
      const session = ctx.chatRepo.getSession(req.params.id, ownerScope(req.principal!));
      if (!session) throw new NotFoundError("Чат не найден.");
      return { session, messages: ctx.chatRepo.listMessages(session.id) };
    });

    instance.delete<{ Params: { id: string } }>("/support/chats/:id", async (req, reply) => {
      const ok = ctx.chatRepo.deleteSession(req.params.id, ownerScope(req.principal!));
      if (!ok) throw new NotFoundError("Чат не найден.");
      reply.status(204);
      return null;
    });

    instance.post<{ Params: { id: string }; Body: { content: string; stream?: boolean } }>(
      "/support/chats/:id/messages",
      { schema: { body: sendChatMessageBody } },
      async (req, reply) => {
        const owner = ownerScope(req.principal!);
        const session = ctx.chatRepo.getSession(req.params.id, owner);
        if (!session) throw new NotFoundError("Чат не найден.");
        const content = req.body.content.trim();
        if (!content) throw new ValidationError("Пустое сообщение.");

        const now = ctx.now().toISOString();
        // Сохраняем вопрос ДО генерации: таймаут не должен его терять.
        const existing = ctx.chatRepo.listMessages(session.id);
        if (existing.length === 0 && !session.title) {
          ctx.chatRepo.setTitle(session.id, autoTitle(content));
        }
        const userMessage = ctx.chatRepo.appendMessage(session.id, {
          id: randomUUID(),
          role: "user",
          content,
          createdAt: now,
        });
        const history: HistoryMessage[] = [...existing, userMessage].map((m) => ({
          role: m.role,
          content: m.content,
        }));
        const userEmail = req.principal!.user?.email || null;

        return respond(
          ctx,
          req,
          reply,
          req.body.stream === true,
          (opts) => ctx.chat.answer({ history, userEmail, ...opts }),
          (res) => {
            const assistantMessage = ctx.chatRepo.appendMessage(session.id, {
              id: randomUUID(),
              role: "assistant",
              content: res.content,
              usage: res.usage,
              toolCalls: res.toolCalls,
              createdAt: ctx.now().toISOString(),
            });
            return {
              userMessage,
              assistantMessage,
              usage: res.usage,
              timings: res.timings,
              toolCalls: res.toolCalls,
              sources: res.sources,
              droppedCount: res.droppedCount,
            };
          },
        );
      },
    );
  });
}
