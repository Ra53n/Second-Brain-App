// Тесты агентного tool-loop и stripModelMarkup.

import { describe, expect, it } from "vitest";
import {
  runToolLoop,
  stripModelMarkup,
  type ChatCompletion,
  type ChatRequest,
  type LlmCompletionClient,
  type ToolDef,
} from "../src/llm/openaiClient.js";

const TOOLS: ToolDef[] = [
  { type: "function", function: { name: "crm__get_ticket", parameters: {} } },
];

function stubClient(script: Array<(req: ChatRequest) => ChatCompletion>): LlmCompletionClient {
  let i = 0;
  return {
    async chat(req) {
      const step = script[Math.min(i, script.length - 1)]!;
      i++;
      return step(req);
    },
  };
}

const usage = { promptTokens: 10, completionTokens: 5, totalTokens: 15 };

describe("runToolLoop", () => {
  it("без tool_calls — сразу финальный текст", async () => {
    const client = stubClient([() => ({ message: { content: "Ответ" }, usage })]);
    const res = await runToolLoop({
      client,
      model: "m",
      temperature: 0,
      maxTokens: 100,
      messages: [{ role: "user", content: "Вопрос" }],
      tools: TOOLS,
      maxIterations: 3,
      execute: async () => "не должно вызываться",
    });
    expect(res.text).toBe("Ответ");
    expect(res.transcript).toEqual([]);
    expect(res.usage.totalTokens).toBe(15);
  });

  it("исполняет tool_calls и передаёт результат обратно", async () => {
    const calls: string[] = [];
    const client = stubClient([
      () => ({
        message: {
          content: null,
          tool_calls: [
            { id: "1", type: "function", function: { name: "crm__get_ticket", arguments: '{"id":"t-101"}' } },
          ],
        },
        usage,
      }),
      (req) => {
        // Результат инструмента должен попасть в сообщения.
        const toolMsg = req.messages.find((m) => m.role === "tool");
        expect(toolMsg?.content).toBe("данные тикета");
        return { message: { content: "Финал с учётом тикета" }, usage };
      },
    ]);
    const res = await runToolLoop({
      client,
      model: "m",
      temperature: 0,
      maxTokens: 100,
      messages: [{ role: "user", content: "почему не работает авторизация" }],
      tools: TOOLS,
      maxIterations: 3,
      execute: async (name, args) => {
        calls.push(`${name}:${args}`);
        return "данные тикета";
      },
    });
    expect(calls).toEqual(['crm__get_ticket:{"id":"t-101"}']);
    expect(res.text).toBe("Финал с учётом тикета");
    expect(res.transcript).toEqual([{ name: "crm__get_ticket", ok: true }]);
    expect(res.usage.totalTokens).toBe(30);
  });

  it("ERROR-результат инструмента помечается ok=false", async () => {
    const client = stubClient([
      () => ({
        message: {
          content: null,
          tool_calls: [{ id: "1", type: "function", function: { name: "crm__get_ticket", arguments: "{}" } }],
        },
        usage,
      }),
      () => ({ message: { content: "Финал" }, usage }),
    ]);
    const res = await runToolLoop({
      client,
      model: "m",
      temperature: 0,
      maxTokens: 100,
      messages: [{ role: "user", content: "в" }],
      tools: TOOLS,
      maxIterations: 3,
      execute: async () => "ERROR: сервер недоступен",
    });
    expect(res.transcript).toEqual([{ name: "crm__get_ticket", ok: false }]);
  });

  it("на последней итерации tools не передаются и добавляется СТОП-нудж", async () => {
    const seen: Array<{ hasTools: boolean; last: string }> = [];
    const client = stubClient([
      (req) => {
        seen.push({
          hasTools: !!req.tools,
          last: String(req.messages[req.messages.length - 1]!.content),
        });
        return {
          message: {
            content: null,
            tool_calls: [{ id: "1", type: "function", function: { name: "crm__get_ticket", arguments: "{}" } }],
          },
          usage,
        };
      },
      (req) => {
        seen.push({
          hasTools: !!req.tools,
          last: String(req.messages[req.messages.length - 1]!.content),
        });
        return { message: { content: "Финал" }, usage };
      },
    ]);
    const res = await runToolLoop({
      client,
      model: "m",
      temperature: 0,
      maxTokens: 100,
      messages: [{ role: "user", content: "в" }],
      tools: TOOLS,
      maxIterations: 2,
      execute: async () => "ok",
    });
    expect(res.text).toBe("Финал");
    expect(seen[0]!.hasTools).toBe(true);
    expect(seen[1]!.hasTools).toBe(false);
    expect(seen[1]!.last).toContain("СТОП");
  });

  it("onToolCall шлёт статусы", async () => {
    const statuses: string[] = [];
    const client = stubClient([
      () => ({
        message: {
          content: null,
          tool_calls: [{ id: "1", type: "function", function: { name: "crm__find_user", arguments: "{}" } }],
        },
        usage,
      }),
      () => ({ message: { content: "Финал" }, usage }),
    ]);
    await runToolLoop({
      client,
      model: "m",
      temperature: 0,
      maxTokens: 100,
      messages: [{ role: "user", content: "в" }],
      tools: TOOLS,
      maxIterations: 3,
      execute: async () => "ok",
      onToolCall: (name) => statuses.push(name),
    });
    expect(statuses).toEqual(["crm__find_user"]);
  });
});

describe("stripModelMarkup", () => {
  it("срезает DSML/tool-разметку", () => {
    expect(stripModelMarkup("Ответ <｜DSML｜>мусор")).toBe("Ответ");
    expect(stripModelMarkup("Чистый текст")).toBe("Чистый текст");
  });
});
