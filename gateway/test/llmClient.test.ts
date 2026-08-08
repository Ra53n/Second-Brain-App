// llmClient.test.ts — поведение клиента при зависшем и странном upstream.
// Регрессия боевого инцидента: DeepSeek снял модель deepseek-chat и на запрос
// с ней перестал отвечать вообще — запрос висел вечно.

import { describe, it, expect, vi } from "vitest";
import { HttpLlmClient } from "../src/llm/openaiClient.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const REQ = {
  model: "deepseek-v4-flash",
  messages: [{ role: "user" as const, content: "привет" }],
  temperature: 0.4,
  maxTokens: 100,
};

describe("HttpLlmClient — зависший upstream", () => {
  it("молчащий upstream обрывается по таймауту, а не висит вечно", async () => {
    // fetch, который никогда не резолвится, пока его не оборвут сигналом.
    const hangingFetch = vi.fn((_url: any, init: any) =>
      new Promise<Response>((_resolve, reject) => {
        init.signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
      }),
    ) as unknown as typeof fetch;

    const client = new HttpLlmClient({
      url: "https://api.example/chat",
      apiKey: "k",
      timeoutMs: 20,
      maxRetries: 1,
      fetchImpl: hangingFetch,
      sleep: async () => {},
    });

    await expect(client.chat(REQ)).rejects.toThrow(/не ответила за/i);
    // Первая попытка + один повтор.
    expect((hangingFetch as any).mock.calls.length).toBe(2);
  });

  it("отмена вызывающим пробрасывается как AbortError, не как таймаут", async () => {
    const outer = new AbortController();
    const hangingFetch = vi.fn((_url: any, init: any) =>
      new Promise<Response>((_resolve, reject) => {
        init.signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
      }),
    ) as unknown as typeof fetch;

    const client = new HttpLlmClient({
      url: "https://api.example/chat",
      apiKey: "k",
      timeoutMs: 10_000,
      fetchImpl: hangingFetch,
      sleep: async () => {},
    });
    const p = client.chat({ ...REQ, signal: outer.signal });
    outer.abort();
    await expect(p).rejects.toThrow(/abort/i);
  });
});

describe("HttpLlmClient — reasoning-модели", () => {
  it("пустой content при непустом reasoning_content → понятная ошибка про лимит", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({
        choices: [{ message: { content: "", reasoning_content: "долго думал" } }],
        usage: { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 },
      }),
    ) as unknown as typeof fetch;

    const client = new HttpLlmClient({ url: "https://api.example/chat", apiKey: "k", fetchImpl });
    await expect(client.chat(REQ)).rejects.toThrow(/лимит токенов на рассуждения/i);
  });

  it("нормальный ответ с reasoning_content отдаётся по content", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({
        choices: [{ message: { content: "готово", reasoning_content: "думал" } }],
        usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
      }),
    ) as unknown as typeof fetch;

    const client = new HttpLlmClient({ url: "https://api.example/chat", apiKey: "k", fetchImpl });
    const r = await client.chat(REQ);
    expect(r.message.content).toBe("готово");
    expect(r.usage.totalTokens).toBe(15);
  });
});
