// Тесты ядра чата: assembleMessages (бюджет контекста), FifoGate (очередь),
// SupportChatService.answer (сборка промпта: CRM-контекст + RAG-блок).

import { beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  FifoGate,
  SupportChatService,
  assembleMessages,
  estimateTokens,
} from "../src/chat/supportChatService.js";
import { BusyError, ValidationError } from "../src/domain/errors.js";
import { openDb } from "../src/store/db.js";
import { KbRepo } from "../src/store/kbRepo.js";
import { KbIndexer } from "../src/rag/indexer.js";
import { HashingEmbedder } from "../src/rag/embedder.js";
import { SettingsRepo } from "../src/store/settingsRepo.js";
import { SettingsService } from "../src/settings/settingsService.js";
import { CrmStore } from "../src/crm/crmStore.js";
import { OllamaClient } from "../src/llm/ollamaClient.js";
import type { McpHost } from "../src/mcp/mcpHost.js";
import type { LlmCompletionClient } from "../src/llm/openaiClient.js";

describe("assembleMessages", () => {
  it("системный промпт первый, последнее сообщение сохраняется", () => {
    const { messages, droppedCount } = assembleMessages({
      systemPrompt: "sys",
      history: [
        { role: "user", content: "первый" },
        { role: "assistant", content: "ответ" },
        { role: "user", content: "последний" },
      ],
      numCtx: 8192,
      maxTokens: 512,
    });
    expect(messages[0]).toEqual({ role: "system", content: "sys" });
    expect(messages.at(-1)).toEqual({ role: "user", content: "последний" });
    expect(droppedCount).toBe(0);
  });

  it("при нехватке бюджета выкидываются старые сообщения", () => {
    const big = "х".repeat(4000); // ~1000 токенов
    const { messages, droppedCount } = assembleMessages({
      systemPrompt: "sys",
      history: [
        { role: "user", content: big },
        { role: "assistant", content: big },
        { role: "user", content: "короткий вопрос" },
      ],
      numCtx: 2048,
      maxTokens: 256,
    });
    expect(droppedCount).toBe(2);
    expect(messages.at(-1)!.content).toBe("короткий вопрос");
  });

  it("сообщение само не влезает → ValidationError", () => {
    expect(() =>
      assembleMessages({
        systemPrompt: "",
        history: [{ role: "user", content: "х".repeat(100000) }],
        numCtx: 2048,
        maxTokens: 256,
      }),
    ).toThrow(ValidationError);
  });

  it("estimateTokens переоценивает (безопасная сторона)", () => {
    expect(estimateTokens("тест")).toBeGreaterThan(1);
  });
});

describe("FifoGate", () => {
  it("переполнение очереди → BusyError", async () => {
    const gate = new FifoGate(1); // 1 исполняется + 1 ждёт
    const r1 = await gate.acquire();
    const p2 = gate.acquire(); // в очередь
    await expect(gate.acquire()).rejects.toThrow(BusyError);
    r1();
    (await p2)();
    expect(gate.stats()).toEqual({ active: 0, waiting: 0 });
  });

  it("отмена ожидающего освобождает место в очереди", async () => {
    const gate = new FifoGate(1);
    const r1 = await gate.acquire();
    const ac = new AbortController();
    const p2 = gate.acquire(ac.signal);
    ac.abort();
    await expect(p2).rejects.toThrow();
    // Очередь свободна — новый ожидающий помещается.
    const p3 = gate.acquire();
    r1();
    (await p3)();
  });
});

// ── SupportChatService.answer ────────────────────────────────────────────────

function makeService(captured: { systemPrompt?: string }) {
  const db = openDb(":memory:");
  const settingsRepo = new SettingsRepo(db);
  const settings = new SettingsService(settingsRepo);
  // Облачный провайдер с ключом — путь через remoteClientFactory-заглушку.
  // minScore=0: у HashingEmbedder скоры ниже, чем у настоящих эмбеддингов.
  settings.update(
    { provider: "deepseek", llmApiKey: "sk-test", rag: { minScore: 0 } },
    "2026-07-18T10:00:00Z",
  );

  const kbRepo = new KbRepo(db);
  const crmDir = mkdtempSync(join(tmpdir(), "crm-svc-"));
  writeFileSync(
    join(crmDir, "users.json"),
    JSON.stringify([
      {
        id: "u-001",
        name: "Мария",
        email: "maria@example.com",
        app_version: "1.2",
        macos_version: "14.5",
        registered_at: "2026-05-02",
        notes: "",
      },
    ]),
    "utf8",
  );
  writeFileSync(
    join(crmDir, "tickets.json"),
    JSON.stringify([
      {
        id: "t-101",
        user_id: "u-001",
        subject: "Не работает авторизация при git push",
        status: "open",
        tags: ["auth"],
        created_at: "2026-07-10T09:12:00Z",
        updated_at: "2026-07-10T09:12:00Z",
        messages: [{ author: "user", text: "authentication failed", at: "2026-07-10T09:12:00Z" }],
      },
    ]),
    "utf8",
  );
  const crm = new CrmStore(crmDir);

  const mcpHost: McpHost = {
    refresh: async () => {},
    availableTools: () => [],
    call: async () => "ERROR: нет",
    statuses: () => [],
    close: async () => {},
  };

  const stubClient: LlmCompletionClient = {
    async chat(req) {
      captured.systemPrompt = String(req.messages[0]!.content);
      return {
        message: { content: "Похоже, у вас истёк GitHub-токен (тикет t-101)." },
        usage: { promptTokens: 10, completionTokens: 5, totalTokens: 15 },
      };
    },
  };

  const embedder = new HashingEmbedder(64);
  const service = new SupportChatService(
    {
      settings,
      ollama: new OllamaClient({ baseUrl: "http://unused" }),
      kbRepo,
      crm,
      mcpHost,
    },
    {
      remoteClientFactory: () => stubClient,
      embedderFactory: () => embedder,
    },
  );
  return { service, kbRepo, embedder, settings };
}

describe("SupportChatService.answer", () => {
  let captured: { systemPrompt?: string };

  beforeEach(() => {
    captured = {};
  });

  it("инжектит CRM-контекст клиента и RAG-блок в системный промпт", async () => {
    const { service, kbRepo, embedder } = makeService(captured);
    // Проиндексируем мини-KB про git-авторизацию.
    const kbDir = mkdtempSync(join(tmpdir(), "kb-svc-"));
    writeFileSync(
      join(kbDir, "faq.md"),
      "# Авторизация git\nПри ошибке авторизации git push обновите Personal Access Token GitHub.",
      "utf8",
    );
    await new KbIndexer(kbRepo, kbDir).reindex(embedder);

    const res = await service.answer({
      history: [{ role: "user", content: "почему не работает авторизация git push" }],
      userEmail: "maria@example.com",
    });
    expect(res.content).toContain("t-101");
    // Системный промпт содержит и данные клиента, и фрагменты KB.
    expect(captured.systemPrompt).toContain("Мария");
    expect(captured.systemPrompt).toContain("t-101");
    expect(captured.systemPrompt).toContain("faq.md");
    expect(res.sources.length).toBeGreaterThan(0);
  });

  it("без email — без CRM-блока; пустая KB — notFound-директива", async () => {
    const { service } = makeService(captured);
    await service.answer({
      history: [{ role: "user", content: "вопрос" }],
      userEmail: null,
    });
    expect(captured.systemPrompt).not.toContain("Клиент:");
    expect(captured.systemPrompt).toContain("НЕ нашёл релевантных фрагментов");
  });

  it("облачный провайдер без ключа → ValidationError", async () => {
    const { service, settings } = makeService(captured);
    // Сбросить ключ нельзя (write-only), поэтому проверяем на свежем сервисе.
    const db2 = openDb(":memory:");
    const s2 = new SettingsService(new SettingsRepo(db2));
    s2.update({ provider: "deepseek" }, "2026-07-18T10:00:00Z");
    const svc2 = new SupportChatService(
      {
        settings: s2,
        ollama: new OllamaClient({ baseUrl: "http://unused" }),
        kbRepo: new KbRepo(db2),
        crm: new CrmStore(mkdtempSync(join(tmpdir(), "crm-e-"))),
        mcpHost: {
          refresh: async () => {},
          availableTools: () => [],
          call: async () => "",
          statuses: () => [],
          close: async () => {},
        },
      },
      { embedderFactory: () => new HashingEmbedder(8) },
    );
    await expect(
      svc2.answer({ history: [{ role: "user", content: "в" }], userEmail: null }),
    ).rejects.toThrow(ValidationError);
    expect(settings).toBeDefined();
  });

  it("история должна заканчиваться сообщением пользователя", async () => {
    const { service } = makeService(captured);
    await expect(
      service.answer({
        history: [{ role: "assistant", content: "ответ" }],
        userEmail: null,
      }),
    ).rejects.toThrow(ValidationError);
  });
});
