// Интеграционные тесты HTTP-слоя (Fastify inject): health, логин-flow,
// owner-scope чатов, admin-зона (401/403), path traversal в KB.

import { beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { FastifyInstance } from "fastify";
import { openDb } from "../src/store/db.js";
import { SettingsRepo } from "../src/store/settingsRepo.js";
import { SettingsService } from "../src/settings/settingsService.js";
import { McpServersRepo } from "../src/store/mcpServersRepo.js";
import { OllamaClient } from "../src/llm/ollamaClient.js";
import { ChatRepo } from "../src/store/chatRepo.js";
import { UsersRepo } from "../src/store/usersRepo.js";
import { AuthService } from "../src/auth/authService.js";
import { KbRepo } from "../src/store/kbRepo.js";
import { KbIndexer } from "../src/rag/indexer.js";
import { HashingEmbedder } from "../src/rag/embedder.js";
import { CrmStore } from "../src/crm/crmStore.js";
import { SupportChatService } from "../src/chat/supportChatService.js";
import { buildApp } from "../src/http/app.js";
import type { AppContext } from "../src/http/context.js";
import type { McpHost } from "../src/mcp/mcpHost.js";
import type { LlmCompletionClient } from "../src/llm/openaiClient.js";

const API_TOKEN = "test-api-token";

interface TestEnv {
  app: FastifyInstance;
  auth: AuthService;
  kbDir: string;
}

function makeEnv(): TestEnv {
  const db = openDb(":memory:");
  const settings = new SettingsService(new SettingsRepo(db));
  // Облачный провайдер + заглушка клиента, чтобы чат не ходил в сеть.
  settings.update({ provider: "deepseek", llmApiKey: "sk-test" }, "2026-07-18T10:00:00Z");

  const kbDir = mkdtempSync(join(tmpdir(), "kb-api-"));
  writeFileSync(join(kbDir, "faq.md"), "# FAQ\nПро git-авторизацию: обновите токен.", "utf8");
  const crmDir = mkdtempSync(join(tmpdir(), "crm-api-"));
  writeFileSync(join(crmDir, "users.json"), "[]", "utf8");
  writeFileSync(join(crmDir, "tickets.json"), "[]", "utf8");

  const mcpHost: McpHost = {
    refresh: async () => {},
    availableTools: () => [],
    call: async () => "ERROR: нет",
    statuses: () => [],
    close: async () => {},
  };
  const stubClient: LlmCompletionClient = {
    async chat() {
      return {
        message: { content: "Ответ ассистента" },
        usage: { promptTokens: 1, completionTokens: 1, totalTokens: 2 },
      };
    },
  };

  const ollama = new OllamaClient({ baseUrl: "http://unused", maxRetries: 0 });
  const kbRepo = new KbRepo(db);
  const auth = new AuthService(new UsersRepo(db));
  const embedder = new HashingEmbedder(32);
  const chat = new SupportChatService(
    { settings, ollama, kbRepo, crm: new CrmStore(crmDir), mcpHost },
    { remoteClientFactory: () => stubClient, embedderFactory: () => embedder },
  );

  const ctx: AppContext = {
    settings,
    mcpServersRepo: new McpServersRepo(db),
    mcpHost,
    ollama,
    chat,
    chatRepo: new ChatRepo(db),
    auth,
    kbRepo,
    kbIndexer: new KbIndexer(kbRepo, kbDir),
    embedderFactory: () => embedder,
    crm: new CrmStore(crmDir),
    kbDir,
    apiToken: API_TOKEN,
    sessionSecret: "test-session-secret",
    now: () => new Date("2026-07-18T10:00:00Z"),
  };
  return { app: buildApp(ctx), auth, kbDir };
}

/** Логин через API; возвращает cookie-заголовок для следующих запросов. */
async function login(env: TestEnv, username: string, password: string): Promise<string> {
  const res = await env.app.inject({
    method: "POST",
    url: "/support/auth/login",
    payload: { username, password },
  });
  expect(res.statusCode).toBe(200);
  const setCookie = res.headers["set-cookie"];
  const raw = Array.isArray(setCookie) ? setCookie[0]! : String(setCookie);
  return raw.split(";")[0]!;
}

let env: TestEnv;

beforeEach(async () => {
  env = makeEnv();
  await env.auth.createUser("admin", "admin-pass", { isAdmin: true });
  await env.auth.createUser("maria", "maria-pass", { email: "maria@example.com" });
});

describe("публичные маршруты", () => {
  it("health отвечает без авторизации", async () => {
    const res = await env.app.inject({ method: "GET", url: "/support/health" });
    expect(res.statusCode).toBe(200);
    expect(res.json().status).toBe("ok");
  });

  it("SPA отдаётся без авторизации", async () => {
    const res = await env.app.inject({ method: "GET", url: "/support/" });
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain("Поддержка Second Brain");
  });

  it("неверный пароль → 401; /auth/me без cookie → user:null", async () => {
    const bad = await env.app.inject({
      method: "POST",
      url: "/support/auth/login",
      payload: { username: "maria", password: "wrong" },
    });
    expect(bad.statusCode).toBe(401);
    const me = await env.app.inject({ method: "GET", url: "/support/auth/me" });
    expect(me.json().user).toBeNull();
  });

  it("login → cookie → /auth/me возвращает пользователя", async () => {
    const cookie = await login(env, "maria", "maria-pass");
    const me = await env.app.inject({
      method: "GET",
      url: "/support/auth/me",
      headers: { cookie },
    });
    expect(me.json().user.username).toBe("maria");
    expect(me.json().user.email).toBe("maria@example.com");
  });
});

describe("чаты: авторизация и owner-scope", () => {
  it("без авторизации → 401", async () => {
    const res = await env.app.inject({ method: "GET", url: "/support/chats" });
    expect(res.statusCode).toBe(401);
  });

  it("bearer-токен даёт доступ (admin-пространство)", async () => {
    const res = await env.app.inject({
      method: "GET",
      url: "/support/chats",
      headers: { authorization: `Bearer ${API_TOKEN}` },
    });
    expect(res.statusCode).toBe(200);
  });

  it("неверный bearer → 401", async () => {
    const res = await env.app.inject({
      method: "GET",
      url: "/support/chats",
      headers: { authorization: "Bearer wrong" },
    });
    expect(res.statusCode).toBe(401);
  });

  it("пользователь не видит чужой чат", async () => {
    const cookieMaria = await login(env, "maria", "maria-pass");
    const created = await env.app.inject({
      method: "POST",
      url: "/support/chats",
      headers: { cookie: cookieMaria },
      payload: {},
    });
    expect(created.statusCode).toBe(201);
    const chatId = created.json().id;

    const cookieAdmin = await login(env, "admin", "admin-pass");
    const foreign = await env.app.inject({
      method: "GET",
      url: `/support/chats/${chatId}`,
      headers: { cookie: cookieAdmin },
    });
    expect(foreign.statusCode).toBe(404);

    const own = await env.app.inject({
      method: "GET",
      url: `/support/chats/${chatId}`,
      headers: { cookie: cookieMaria },
    });
    expect(own.statusCode).toBe(200);
  });

  it("сообщение (без стрима) сохраняет вопрос и ответ", async () => {
    const cookie = await login(env, "maria", "maria-pass");
    const created = await env.app.inject({
      method: "POST",
      url: "/support/chats",
      headers: { cookie },
      payload: {},
    });
    const chatId = created.json().id;
    const res = await env.app.inject({
      method: "POST",
      url: `/support/chats/${chatId}/messages`,
      headers: { cookie },
      payload: { content: "почему не работает авторизация" },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.assistantMessage.content).toBe("Ответ ассистента");
    const full = await env.app.inject({
      method: "GET",
      url: `/support/chats/${chatId}`,
      headers: { cookie },
    });
    expect(full.json().messages).toHaveLength(2);
    expect(full.json().session.title).toContain("почему не работает");
  });
});

describe("admin-зона", () => {
  it("без авторизации → 401, обычный пользователь → 403", async () => {
    const anon = await env.app.inject({ method: "GET", url: "/support/admin/settings" });
    expect(anon.statusCode).toBe(401);
    const cookie = await login(env, "maria", "maria-pass");
    const user = await env.app.inject({
      method: "GET",
      url: "/support/admin/settings",
      headers: { cookie },
    });
    expect(user.statusCode).toBe(403);
  });

  it("admin-cookie и bearer работают; ключ маскируется", async () => {
    const cookie = await login(env, "admin", "admin-pass");
    const viaCookie = await env.app.inject({
      method: "GET",
      url: "/support/admin/settings",
      headers: { cookie },
    });
    expect(viaCookie.statusCode).toBe(200);
    expect(viaCookie.json().hasLlmKey).toBe(true);
    expect(viaCookie.body).not.toContain("sk-test");

    const viaBearer = await env.app.inject({
      method: "PATCH",
      url: "/support/admin/settings",
      headers: { authorization: `Bearer ${API_TOKEN}` },
      payload: { provider: "ollama" },
    });
    expect(viaBearer.statusCode).toBe(200);
    expect(viaBearer.json().provider).toBe("ollama");
  });

  it("KB: список файлов, чтение, path traversal отклоняется", async () => {
    const cookie = await login(env, "admin", "admin-pass");
    const list = await env.app.inject({
      method: "GET",
      url: "/support/admin/kb",
      headers: { cookie },
    });
    expect(list.json().files).toContain("faq.md");

    const file = await env.app.inject({
      method: "GET",
      url: "/support/admin/kb/file?name=faq.md",
      headers: { cookie },
    });
    expect(file.json().content).toContain("git-авторизацию");

    for (const evil of ["../../etc/passwd", "..%2Fsecret.md", "dir/evil.md", "no-extension"]) {
      const res = await env.app.inject({
        method: "GET",
        url: `/support/admin/kb/file?name=${encodeURIComponent(evil)}`,
        headers: { cookie },
      });
      expect([400, 404]).toContain(res.statusCode);
      expect(res.statusCode === 400 || evil.includes("%2F")).toBe(true);
    }
  });

  it("создание/удаление веб-аккаунта через API", async () => {
    const cookie = await login(env, "admin", "admin-pass");
    const created = await env.app.inject({
      method: "POST",
      url: "/support/admin/users",
      headers: { cookie },
      payload: { username: "petr", password: "petr-pass", email: "petr@example.com" },
    });
    expect(created.statusCode).toBe(201);
    const id = created.json().id;
    const del = await env.app.inject({
      method: "DELETE",
      url: `/support/admin/users/${id}`,
      headers: { cookie },
    });
    expect(del.statusCode).toBe(204);
  });
});
