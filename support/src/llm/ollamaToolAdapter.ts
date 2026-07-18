// ollamaToolAdapter.ts — LlmCompletionClient поверх родного /api/chat Ollama.
//
// Зачем: runToolLoop работает с интерфейсом OpenAI (tool_calls c JSON-строкой
// аргументов), а родной API Ollama отдаёт arguments объектом и принимает
// сообщения без tool_call_id. Адаптер конвертирует оба направления, сохраняя
// главное преимущество родного API — options.num_ctx.

import type {
  ChatCompletion,
  ChatMessage,
  ChatRequest,
  LlmCompletionClient,
} from "./openaiClient.js";
import type { OllamaChatMessage, OllamaClient } from "./ollamaClient.js";
import type { ChatParams } from "../domain/chat.js";

/** OpenAI-сообщения → родной формат Ollama. */
export function toOllamaMessages(messages: ChatMessage[]): OllamaChatMessage[] {
  return messages.map((m) => {
    if (m.role === "assistant" && m.tool_calls && m.tool_calls.length > 0) {
      return {
        role: "assistant" as const,
        content: m.content ?? "",
        tool_calls: m.tool_calls.map((tc) => ({
          function: {
            name: tc.function.name,
            arguments: safeParse(tc.function.arguments),
          },
        })),
      };
    }
    // tool-результат: у Ollama нет tool_call_id — роль tool + текст достаточно.
    return { role: m.role, content: m.content ?? "" };
  });
}

function safeParse(json: string): unknown {
  try {
    return JSON.parse(json);
  } catch {
    return {};
  }
}

export class OllamaToolAdapter implements LlmCompletionClient {
  constructor(
    private readonly ollama: OllamaClient,
    private readonly opts: { numCtx: number; topP: number; keepAlive?: string },
  ) {}

  async chat(req: ChatRequest): Promise<ChatCompletion> {
    const params: ChatParams = {
      numCtx: this.opts.numCtx,
      temperature: req.temperature,
      topP: this.opts.topP,
      maxTokens: req.maxTokens,
    };
    const res = await this.ollama.chat({
      model: req.model,
      messages: toOllamaMessages(req.messages),
      params,
      keepAlive: this.opts.keepAlive,
      // toolChoice="none"/последняя итерация → tools не передаются (undefined).
      tools: req.toolChoice === "none" ? undefined : req.tools,
      signal: req.signal,
    });
    return {
      message: {
        content: res.content || null,
        tool_calls: res.toolCalls.length > 0 ? res.toolCalls : undefined,
      },
      usage: {
        promptTokens: res.usage.promptTokens,
        completionTokens: res.usage.completionTokens,
        totalTokens: res.usage.promptTokens + res.usage.completionTokens,
      },
    };
  }
}
