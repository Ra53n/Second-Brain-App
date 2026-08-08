// api.test.ts — HTTP-слой: health, чат, admin-скоуп, rate limit.

import { describe, it, expect, beforeEach } from "vitest";
import type { FastifyInstance } from "fastify";
import { openDb } from "../src/store/db.js";
import { SettingsRepo } from "../src/store/settingsRepo.js";
import { AuditRepo } from "../src/store/auditRepo.js";
import { GatewayService } from "../src/chat/gatewayService.js";
import { buildApp } from "../src/http/app.js";
import type { AppContext } from "../src/http/context.js";
import type { Usage } from "../src/llm/openaiClient.js";

const TOKEN = "test-admin-token";
const USAGE: Usage = { promptTokens: 20, completionTokens: 10, totalTokens: 30 };

async function build(rateLimitPerMin = 100): Promise<{ app: FastifyInstance; audit: AuditRepo }> {
  const db = openDb(":memory:");
  const settingsRepo = new SettingsRepo(db);
  const auditRepo = new AuditRepo(db);
  settingsRepo.update({ llmApiKey: "sk-fake-000", rateLimitPerMin });
  const gateway = new GatewayService(settingsRepo, auditRepo, () => ({
    async chat() {
      return { message: { content: "Готово." }, usage: USAGE };
    },
  }));
  const ctx: AppContext = { settingsRepo, auditRepo, gateway, apiToken: TOKEN };
  return { app: await buildApp(ctx), audit: auditRepo };
}

describe("HTTP API", () => {
  let app: FastifyInstance;
  beforeEach(async () => {
    app = (await build()).app;
  });

  it("GET /gw/health → ok", async () => {
    const r = await app.inject({ method: "GET", url: "/gw/health" });
    expect(r.statusCode).toBe(200);
    expect(r.json().status).toBe("ok");
  });

  it("POST /gw/chat → 200 с ответом и мета", async () => {
    const r = await app.inject({ method: "POST", url: "/gw/chat", payload: { prompt: "привет" } });
    expect(r.statusCode).toBe(200);
    const j = r.json();
    expect(j.answer).toBe("Готово.");
    expect(j.meta.usage.totalTokens).toBe(30);
    expect(j.meta.costUsd).toBeGreaterThan(0);
  });

  it("POST /gw/chat с пустым промптом → 400", async () => {
    const r = await app.inject({ method: "POST", url: "/gw/chat", payload: { prompt: "" } });
    expect(r.statusCode).toBe(400);
  });

  it("admin без токена → 401", async () => {
    const r = await app.inject({ method: "GET", url: "/gw/admin/settings" });
    expect(r.statusCode).toBe(401);
  });

  it("admin с токеном → настройки без ключа (только hasLlmKey+tail)", async () => {
    const r = await app.inject({
      method: "GET",
      url: "/gw/admin/settings",
      headers: { authorization: `Bearer ${TOKEN}` },
    });
    expect(r.statusCode).toBe(200);
    const j = r.json();
    expect(j.hasLlmKey).toBe(true);
    expect(j.llmApiKey).toBeUndefined();
  });

  it("PUT admin settings меняет политику; пустой ключ не затирает", async () => {
    const r = await app.inject({
      method: "PUT",
      url: "/gw/admin/settings",
      headers: { authorization: `Bearer ${TOKEN}` },
      payload: { inputPolicy: "block", llmApiKey: "" },
    });
    expect(r.statusCode).toBe(200);
    expect(r.json().inputPolicy).toBe("block");
    expect(r.json().hasLlmKey).toBe(true); // ключ сохранён
  });

  it("перехваты видны в /gw/admin/interceptions", async () => {
    await app.inject({ method: "POST", url: "/gw/chat", payload: { prompt: "ключ AKIAIOSFODNN7EXAMPLE" } });
    const r = await app.inject({
      method: "GET",
      url: "/gw/admin/interceptions",
      headers: { authorization: `Bearer ${TOKEN}` },
    });
    expect(r.statusCode).toBe(200);
    expect(r.json().items.length).toBeGreaterThanOrEqual(1);
  });

  it("rate limit: сверх лимита в минуту → 429", async () => {
    const built = await build(2);
    const send = () =>
      built.app.inject({
        method: "POST",
        url: "/gw/chat",
        headers: { "x-forwarded-for": "9.9.9.9" },
        payload: { prompt: "hi" },
      });
    expect((await send()).statusCode).toBe(200);
    expect((await send()).statusCode).toBe(200);
    const over = await send();
    expect(over.statusCode).toBe(429);
    // 429 отдаётся в едином конверте {error:{code:"busy"}}.
    expect(over.json().error.code).toBe("busy");
  });
});
