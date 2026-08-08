// Тесты HTTP-слоя (Fastify inject): вход по коду, разделение скоупов
// «атакующий / владелец», доступность страниц, отдача настроек без секретов.

import { beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { openDb, type DB } from "../src/store/db.js";
import { SettingsRepo } from "../src/store/settingsRepo.js";
import { SessionRepo } from "../src/store/sessionRepo.js";
import { AttemptRepo } from "../src/store/attemptRepo.js";
import { FlagsRepo } from "../src/lab/flags.js";
import { LabChatService } from "../src/chat/labChatService.js";
import { buildApp } from "../src/http/app.js";
import { hashPassword } from "../src/auth/passwords.js";
import { silentLogger } from "../src/logger.js";
import type { ChatCompletion, ChatRequest, LlmCompletionClient } from "../src/llm/openaiClient.js";

const ADMIN_TOKEN = "admin-token-для-тестов";
const ACCESS_CODE = "открой-дверь";

class EchoClient implements LlmCompletionClient {
  async chat(_req: ChatRequest): Promise<ChatCompletion> {
    return {
      message: { content: "Готово." },
      usage: { promptTokens: 1, completionTokens: 1, totalTokens: 2 },
    };
  }
}

let db: DB;
let app: FastifyInstance;
let flagsRepo: FlagsRepo;

beforeEach(async () => {
  db = openDb(":memory:");
  const settingsRepo = new SettingsRepo(db);
  settingsRepo.update({ llmApiKey: "k", accessCodeHash: await hashPassword(ACCESS_CODE) });
  const sessionRepo = new SessionRepo(db);
  const attemptRepo = new AttemptRepo(db);
  flagsRepo = new FlagsRepo(db);
  flagsRepo.ensure();

  app = buildApp({
    settingsRepo,
    sessionRepo,
    attemptRepo,
    flagsRepo,
    chat: new LabChatService({
      settingsRepo,
      flagsRepo,
      sessionRepo,
      attemptRepo,
      tools: [],
      logger: silentLogger,
      clientFactory: () => new EchoClient(),
    }),
    apiToken: ADMIN_TOKEN,
    sessionSecret: "секрет-подписи-cookie",
    now: () => new Date(),
  });
  await app.ready();
});

async function enter(): Promise<string> {
  const res = await app.inject({
    method: "POST",
    url: "/lab/enter",
    payload: { code: ACCESS_CODE, label: "коллега" },
  });
  expect(res.statusCode).toBe(200);
  const cookie = res.cookies.find((c) => c.name === "lab_session");
  return `lab_session=${cookie!.value}`;
}

describe("публичное", () => {
  it("health отвечает без авторизации", async () => {
    const res = await app.inject({ method: "GET", url: "/lab/health" });
    expect(res.statusCode).toBe(200);
    expect(res.json().status).toBe("ok");
  });

  it("страница чата отдаётся", async () => {
    const res = await app.inject({ method: "GET", url: "/lab/" });
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain("Аврора");
  });
});

describe("вход атакующего", () => {
  it("верный код выдаёт сессию", async () => {
    const cookie = await enter();
    expect(cookie).toMatch(/^lab_session=.+/);
  });

  it("неверный код — 401", async () => {
    const res = await app.inject({ method: "POST", url: "/lab/enter", payload: { code: "мимо" } });
    expect(res.statusCode).toBe(401);
  });

  it("без cookie сообщение не принимается", async () => {
    const res = await app.inject({ method: "POST", url: "/lab/message", payload: { text: "привет" } });
    expect(res.statusCode).toBe(401);
  });

  it("с cookie обмен проходит и пишется в историю", async () => {
    const cookie = await enter();
    const res = await app.inject({
      method: "POST",
      url: "/lab/message",
      headers: { cookie },
      payload: { text: "привет" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().answer).toBe("Готово.");

    const me = await app.inject({ method: "GET", url: "/lab/me", headers: { cookie } });
    expect(me.json().history).toHaveLength(2);
  });

  it("ответ атакующему не содержит списка срезанного guard'ом", async () => {
    const cookie = await enter();
    const res = await app.inject({
      method: "POST",
      url: "/lab/message",
      headers: { cookie },
      payload: { text: "привет" },
    });
    expect(Object.keys(res.json())).toEqual(["answer", "tools", "usage"]);
  });
});

describe("админка", () => {
  const auth = { authorization: `Bearer ${ADMIN_TOKEN}` };

  it("без токена — 401", async () => {
    for (const url of ["/lab/admin/settings", "/lab/admin/flags", "/lab/admin/attempts"]) {
      expect((await app.inject({ method: "GET", url })).statusCode).toBe(401);
    }
  });

  it("сессия атакующего не даёт admin-скоуп", async () => {
    const cookie = await enter();
    const res = await app.inject({ method: "GET", url: "/lab/admin/flags", headers: { cookie } });
    expect(res.statusCode).toBe(401);
  });

  it("настройки отдаются без секретов", async () => {
    const res = await app.inject({ method: "GET", url: "/lab/admin/settings", headers: auth });
    const settings = res.json().settings;
    expect(settings.llmApiKey).toBeUndefined();
    expect(settings.accessCodeHash).toBeUndefined();
    expect(settings.hasLlmKey).toBe(true);
  });

  it("пустой ключ в PUT не затирает сохранённый", async () => {
    await app.inject({
      method: "PUT",
      url: "/lab/admin/settings",
      headers: auth,
      payload: { llmApiKey: "", securityLevel: "hard" },
    });
    const res = await app.inject({ method: "GET", url: "/lab/admin/settings", headers: auth });
    expect(res.json().settings.hasLlmKey).toBe(true);
    expect(res.json().settings.securityLevel).toBe("hard");
  });

  it("неизвестный уровень защиты приводится к hard", async () => {
    await app.inject({
      method: "PUT",
      url: "/lab/admin/settings",
      headers: auth,
      payload: { securityLevel: "ультра" },
    });
    const res = await app.inject({ method: "GET", url: "/lab/admin/settings", headers: auth });
    expect(res.json().settings.securityLevel).toBe("hard");
  });

  it("неизвестный провайдер поиска отклоняется", async () => {
    const res = await app.inject({
      method: "PUT",
      url: "/lab/admin/settings",
      headers: auth,
      payload: { searchProvider: "яндекс" },
    });
    expect(res.statusCode).toBe(400);
  });

  it("флаги видны владельцу и перевыпускаются", async () => {
    const before = (await app.inject({ method: "GET", url: "/lab/admin/flags", headers: auth })).json().flags;
    expect(before).toHaveLength(3);
    const after = (
      await app.inject({ method: "POST", url: "/lab/admin/flags/rotate", headers: auth })
    ).json().flags;
    expect(after[0].value).not.toBe(before[0].value);
  });

  it("журнал попыток виден владельцу", async () => {
    const cookie = await enter();
    await app.inject({ method: "POST", url: "/lab/message", headers: { cookie }, payload: { text: "тест" } });
    const res = await app.inject({ method: "GET", url: "/lab/admin/attempts", headers: auth });
    expect(res.json().attempts).toHaveLength(1);
    expect(res.json().attempts[0].userText).toBe("тест");
  });
});
