// Тесты адаптера родного API Ollama под интерфейс LlmCompletionClient.

import { describe, expect, it } from "vitest";
import { OllamaClient } from "../src/llm/ollamaClient.js";
import { OllamaToolAdapter, toOllamaMessages } from "../src/llm/ollamaToolAdapter.js";
import type { ToolDef } from "../src/llm/openaiClient.js";

function fakeFetch(handler: (url: string, body: any) => unknown): typeof fetch {
  return (async (url: any, init: any) => {
    const body = init?.body ? JSON.parse(init.body) : {};
    const result = handler(String(url), body);
    return new Response(JSON.stringify(result), { status: 200 });
  }) as typeof fetch;
}

const TOOLS: ToolDef[] = [
  { type: "function", function: { name: "crm__get_ticket", parameters: { type: "object" } } },
];

describe("toOllamaMessages", () => {
  it("assistant с tool_calls: arguments-строка парсится в объект", () => {
    const out = toOllamaMessages([
      {
        role: "assistant",
        content: null,
        tool_calls: [
          { id: "1", type: "function", function: { name: "t", arguments: '{"id":"x"}' } },
        ],
      },
      { role: "tool", content: "результат", tool_call_id: "1" },
    ]);
    expect(out[0]!.tool_calls![0]!.function.arguments).toEqual({ id: "x" });
    expect(out[1]).toEqual({ role: "tool", content: "результат" });
  });
});

describe("OllamaToolAdapter", () => {
  it("прокидывает num_ctx/tools и конвертирует tool_calls ответа", async () => {
    let captured: any;
    const ollama = new OllamaClient({
      baseUrl: "http://test",
      fetchImpl: fakeFetch((url, body) => {
        captured = { url, body };
        return {
          message: {
            content: "",
            tool_calls: [{ function: { name: "crm__get_ticket", arguments: { id: "t-101" } } }],
          },
          prompt_eval_count: 12,
          eval_count: 3,
        };
      }),
    });
    const adapter = new OllamaToolAdapter(ollama, { numCtx: 8192, topP: 0.95 });
    const res = await adapter.chat({
      model: "qwen3:4b",
      messages: [{ role: "user", content: "вопрос" }],
      temperature: 0.3,
      maxTokens: 512,
      tools: TOOLS,
    });
    expect(captured.url).toContain("/api/chat");
    expect(captured.body.options.num_ctx).toBe(8192);
    expect(captured.body.options.num_predict).toBe(512);
    expect(captured.body.tools).toHaveLength(1);
    expect(res.message.tool_calls![0]!.function.name).toBe("crm__get_ticket");
    // arguments-объект сериализован в JSON-строку (формат OpenAI).
    expect(JSON.parse(res.message.tool_calls![0]!.function.arguments)).toEqual({ id: "t-101" });
    expect(res.usage.totalTokens).toBe(15);
  });

  it("toolChoice=none → tools не передаются", async () => {
    let captured: any;
    const ollama = new OllamaClient({
      baseUrl: "http://test",
      fetchImpl: fakeFetch((_url, body) => {
        captured = body;
        return { message: { content: "Финал" }, prompt_eval_count: 1, eval_count: 1 };
      }),
    });
    const adapter = new OllamaToolAdapter(ollama, { numCtx: 4096, topP: 0.9 });
    const res = await adapter.chat({
      model: "m",
      messages: [{ role: "user", content: "в" }],
      temperature: 0,
      maxTokens: 10,
      tools: TOOLS,
      toolChoice: "none",
    });
    expect(captured.tools).toBeUndefined();
    expect(res.message.content).toBe("Финал");
  });
});
