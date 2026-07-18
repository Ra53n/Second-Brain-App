// routes.admin.ts — админ-зона: настройки, модели, база знаний (редактор +
// переиндексация + тестовый поиск), CRM-редакторы, MCP-серверы, веб-аккаунты.
// Всё под requireAdmin (bearer SUPPORT_API_TOKEN ИЛИ cookie-сессия админа).

import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { NotFoundError, ValidationError } from "../domain/errors.js";
import { requireAdmin } from "./authMiddleware.js";
import type { McpServerConfig, UpdateSupportSettingsInput } from "../domain/types.js";
import { searchKb } from "../rag/retriever.js";
import {
  createUserBody,
  crmArrayBody,
  kbFileBody,
  kbFileQuery,
  kbSearchBody,
  mcpServersBody,
  settingsBody,
  ticketCommentBody,
  ticketStatusBody,
} from "./schemas.js";
import type { TicketStatus } from "../domain/types.js";

/** Известные облачные модели для пикера (админ может вписать любую строку). */
const REMOTE_MODEL_SUGGESTIONS: Record<string, string[]> = {
  deepseek: ["deepseek-chat", "deepseek-reasoner"],
  openrouter: [
    "deepseek/deepseek-chat-v3-0324",
    "openai/gpt-4o-mini",
    "anthropic/claude-sonnet-4",
    "qwen/qwen3-32b",
  ],
};

/**
 * Защита от path traversal: имя KB-файла — только basename с расширением .md,
 * итоговый путь обязан остаться внутри kbDir.
 */
function kbFilePath(kbDir: string, name: string): string {
  const clean = basename(name.trim());
  if (!clean || clean !== name.trim() || !clean.endsWith(".md")) {
    throw new ValidationError("Имя файла — только «имя.md» без путей.");
  }
  const full = resolve(join(kbDir, clean));
  if (!full.startsWith(resolve(kbDir) + "/")) {
    throw new ValidationError("Недопустимый путь файла.");
  }
  return full;
}

function publicMcpList(ctx: AppContext) {
  const configs = ctx.mcpServersRepo.list();
  const byId = new Map(ctx.mcpHost.statuses().map((s) => [s.id, s]));
  return configs.map((c) => {
    const st = byId.get(c.id);
    return {
      id: c.id,
      name: c.name,
      command: c.command,
      args: c.args.map(() => "***"), // секреты в args наружу не отдаём
      enabled: c.enabled,
      connected: st?.connected ?? false,
      toolCount: st?.toolCount ?? 0,
      error: st?.error ?? null,
    };
  });
}

export function registerAdminRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.register(async (instance) => {
    instance.addHook("preHandler", requireAdmin(ctx.apiToken, ctx.auth));

    // ── Настройки ─────────────────────────────────────────────────────────────
    instance.get("/support/admin/settings", async () => ctx.settings.getPublic());

    instance.patch<{ Body: UpdateSupportSettingsInput }>(
      "/support/admin/settings",
      { schema: { body: settingsBody } },
      async (req) => ctx.settings.update(req.body, ctx.now().toISOString()),
    );

    // Модели: локальные из Ollama (/api/tags) + статические подсказки облачных.
    instance.get("/support/admin/models", async () => {
      let local: Array<{ name: string; parameterSize: string | null }> = [];
      try {
        local = (await ctx.ollama.listModels()).map((m) => ({
          name: m.name,
          parameterSize: m.parameterSize,
        }));
      } catch {
        /* Ollama недоступна — пустой список, админка покажет предупреждение */
      }
      return { local, remote: REMOTE_MODEL_SUGGESTIONS };
    });

    // ── База знаний ───────────────────────────────────────────────────────────
    instance.get("/support/admin/kb", async () => ({
      files: ctx.kbIndexer.listFiles(),
      meta: ctx.kbRepo.getMeta(),
      indexing: ctx.kbIndexer.isRunning(),
    }));

    instance.get<{ Querystring: { name: string } }>(
      "/support/admin/kb/file",
      { schema: { querystring: kbFileQuery } },
      async (req) => {
        const path = kbFilePath(ctx.kbDir, req.query.name);
        try {
          return { name: basename(path), content: readFileSync(path, "utf8") };
        } catch {
          throw new NotFoundError(`Файл «${req.query.name}» не найден.`);
        }
      },
    );

    instance.put<{ Body: { name: string; content: string } }>(
      "/support/admin/kb/file",
      { schema: { body: kbFileBody } },
      async (req) => {
        const path = kbFilePath(ctx.kbDir, req.body.name);
        writeFileSync(path, req.body.content, "utf8");
        return { ok: true, name: basename(path) };
      },
    );

    instance.delete<{ Querystring: { name: string } }>(
      "/support/admin/kb/file",
      { schema: { querystring: kbFileQuery } },
      async (req, reply) => {
        const path = kbFilePath(ctx.kbDir, req.query.name);
        try {
          unlinkSync(path);
        } catch {
          throw new NotFoundError(`Файл «${req.query.name}» не найден.`);
        }
        reply.status(204);
        return null;
      },
    );

    // Переиндексация — фоном (202); статус опрашивается GET /kb.
    instance.post("/support/admin/kb/reindex", async (req, reply) => {
      if (ctx.kbIndexer.isRunning()) {
        throw new ValidationError("Переиндексация уже идёт.");
      }
      const embedder = ctx.embedderFactory(ctx.settings.getInternal());
      void ctx.kbIndexer.reindex(embedder).catch(() => {
        /* статус/ошибка уже записаны в kb_meta */
      });
      reply.status(202);
      return { status: "indexing" };
    });

    // Тестовый поиск по индексу (отладка качества ретрива из админки).
    instance.post<{ Body: { query: string } }>(
      "/support/admin/kb/search",
      { schema: { body: kbSearchBody } },
      async (req) => {
        const embedder = ctx.embedderFactory(ctx.settings.getInternal());
        const hits = await searchKb(ctx.kbRepo, embedder, req.body.query, 8);
        return {
          hits: hits.map((h) => ({
            path: h.chunk.path,
            section: h.chunk.section,
            score: Math.round(h.score * 1000) / 1000,
            preview: h.chunk.text.slice(0, 240),
          })),
        };
      },
    );

    // ── CRM-редакторы (целиком файл, с валидацией схемы) ──────────────────────
    instance.get("/support/admin/crm/users", async () => ({ items: ctx.crm.listUsers() }));

    instance.put<{ Body: { items: unknown[] } }>(
      "/support/admin/crm/users",
      { schema: { body: crmArrayBody } },
      async (req) => ({ items: ctx.crm.replaceUsers(req.body.items) }),
    );

    // Список обращений для центра поддержки: тикеты + данные клиентов одним ответом.
    instance.get("/support/admin/crm/tickets", async () => {
      const users = new Map(ctx.crm.listUsers().map((u) => [u.id, u]));
      const items = ctx.crm
        .listTickets()
        .map((t) => ({ ...t, user: users.get(t.user_id) ?? null }))
        .sort((a, b) => (a.updated_at < b.updated_at ? 1 : -1));
      return { items };
    });

    instance.post<{ Params: { id: string }; Body: { status: TicketStatus } }>(
      "/support/admin/crm/tickets/:id/status",
      { schema: { body: ticketStatusBody } },
      async (req) => {
        const ticket = ctx.crm.setTicketStatus(req.params.id, req.body.status, ctx.now().toISOString());
        if (!ticket) throw new NotFoundError(`Тикет «${req.params.id}» не найден.`);
        return ticket;
      },
    );

    instance.post<{ Params: { id: string }; Body: { text: string } }>(
      "/support/admin/crm/tickets/:id/comment",
      { schema: { body: ticketCommentBody } },
      async (req) => {
        const ticket = ctx.crm.addTicketComment(
          req.params.id,
          "support",
          req.body.text.trim(),
          ctx.now().toISOString(),
        );
        if (!ticket) throw new NotFoundError(`Тикет «${req.params.id}» не найден.`);
        return ticket;
      },
    );

    instance.put<{ Body: { items: unknown[] } }>(
      "/support/admin/crm/tickets",
      { schema: { body: crmArrayBody } },
      async (req) => ({ items: ctx.crm.replaceTickets(req.body.items) }),
    );

    // ── MCP-серверы ───────────────────────────────────────────────────────────
    instance.get("/support/admin/mcp-servers", async () => ({ items: publicMcpList(ctx) }));

    instance.put<{ Body: { servers: McpServerConfig[] } }>(
      "/support/admin/mcp-servers",
      { schema: { body: mcpServersBody } },
      async (req) => {
        const servers = (req.body.servers ?? []).map((s) => ({
          id: String(s.id),
          name: s.name ?? "",
          command: s.command ?? "node",
          args: Array.isArray(s.args) ? s.args.map(String) : [],
          env: s.env && typeof s.env === "object" ? s.env : {},
          enabled: s.enabled ?? true,
        }));
        ctx.mcpServersRepo.replaceAll(servers, ctx.now().toISOString());
        await ctx.mcpHost.refresh(servers);
        return { items: publicMcpList(ctx) };
      },
    );

    instance.post("/support/admin/mcp-servers/refresh", async () => {
      await ctx.mcpHost.refresh(ctx.mcpServersRepo.list());
      return { items: publicMcpList(ctx) };
    });

    // ── Веб-аккаунты ──────────────────────────────────────────────────────────
    instance.get("/support/admin/users", async () => ({ items: ctx.auth.listUsers() }));

    instance.post<{ Body: { username: string; password: string; email?: string; isAdmin?: boolean } }>(
      "/support/admin/users",
      { schema: { body: createUserBody } },
      async (req, reply) => {
        const user = await ctx.auth.createUser(req.body.username, req.body.password, {
          email: req.body.email,
          isAdmin: req.body.isAdmin ?? false,
        });
        reply.status(201);
        return user;
      },
    );

    instance.delete<{ Params: { id: string } }>("/support/admin/users/:id", async (req, reply) => {
      ctx.auth.deleteUser(req.params.id);
      reply.status(204);
      return null;
    });
  });
}
