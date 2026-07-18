// ollamaClient.ts — клиент РОДНОГО API Ollama (порт runner/ollama.ts MA).
//
// Почему не OpenAI-совместимый /v1: через него у Ollama нельзя задать num_ctx —
// главный рычаг качества маленькой модели. Родной /api/chat принимает
// options.num_ctx/num_predict и отдаёт тайминги. Плюс /api/embed для RAG.
// Ходит на loopback (127.0.0.1:11434) напрямую, без Caddy/токена.

import { UpstreamError } from "../domain/errors.js";
import { abortableDelay } from "./openaiClient.js";
import type { ChatParams, ChatTimings, ChatUsage } from "../domain/chat.js";
import type { ToolCallDTO, ToolDef } from "./openaiClient.js";

export interface OllamaChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  /** tool_calls родного формата (arguments — ОБЪЕКТ, не строка). */
  tool_calls?: Array<{ function: { name: string; arguments: unknown } }>;
}

export interface OllamaChatRequest {
  model: string;
  messages: OllamaChatMessage[];
  params: ChatParams;
  keepAlive?: string;
  /** Инструменты в формате OpenAI — родной /api/chat принимает их как есть. */
  tools?: ToolDef[];
  signal?: AbortSignal;
}

export interface OllamaChatResult {
  content: string;
  /** tool_calls, сконвертированные в OpenAI-формат (arguments — JSON-строка). */
  toolCalls: ToolCallDTO[];
  usage: ChatUsage;
  timings: ChatTimings;
}

export interface OllamaModelInfo {
  name: string;
  sizeBytes: number | null;
  parameterSize: string | null;
  quantization: string | null;
}

export interface OllamaLoadedModel {
  name: string;
  sizeBytes: number | null;
  expiresAt: string | null;
}

export interface OllamaClientConfig {
  baseUrl: string;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
  /** Число ПОВТОРОВ (сверх первой попытки) при транзиентных сбоях. По умолчанию 2. */
  maxRetries?: number;
}

const RETRIABLE_STATUSES = new Set([408, 425, 429, 500, 502, 503, 504]);
const BACKOFF_BASE_MS = 400;
const BACKOFF_CAP_MS = 6000;
const NS_PER_MS = 1_000_000;

function isAbort(e: unknown, signal?: AbortSignal): boolean {
  return !!signal?.aborted || (e instanceof Error && e.name === "AbortError");
}

function nsToMs(ns: unknown): number {
  return typeof ns === "number" && Number.isFinite(ns) ? Math.round(ns / NS_PER_MS) : 0;
}

/** Собирает options родного /api/chat из наших параметров генерации. */
function buildOptions(p: ChatParams): Record<string, unknown> {
  const opts: Record<string, unknown> = {
    num_ctx: p.numCtx,
    num_predict: p.maxTokens, // ВАЖНО: лимит ответа = num_predict, НЕ max_tokens
    temperature: p.temperature,
    top_p: p.topP,
  };
  if (typeof p.repeatPenalty === "number") opts.repeat_penalty = p.repeatPenalty;
  if (typeof p.seed === "number") opts.seed = p.seed;
  return opts;
}

function toUsage(obj: Record<string, unknown>): ChatUsage {
  return {
    promptTokens: (obj.prompt_eval_count as number) ?? 0,
    completionTokens: (obj.eval_count as number) ?? 0,
  };
}

function toTimings(obj: Record<string, unknown>): ChatTimings {
  const evalMs = nsToMs(obj.eval_duration);
  const evalCount = (obj.eval_count as number) ?? 0;
  return {
    loadDurationMs: nsToMs(obj.load_duration),
    promptEvalDurationMs: nsToMs(obj.prompt_eval_duration),
    evalDurationMs: evalMs,
    tokensPerSecond: evalMs > 0 ? Math.round((evalCount / evalMs) * 1000 * 10) / 10 : 0,
  };
}

/** Родные tool_calls → OpenAI-формат (arguments сериализуются в JSON-строку). */
function toToolCallDTOs(message: Record<string, unknown> | undefined): ToolCallDTO[] {
  const raw = (message?.tool_calls as Array<Record<string, unknown>> | undefined) ?? [];
  return raw.map((tc, i) => {
    const fn = (tc.function as { name?: string; arguments?: unknown } | undefined) ?? {};
    return {
      id: `ollama-call-${i}`,
      type: "function" as const,
      function: {
        name: fn.name ?? "",
        arguments: typeof fn.arguments === "string" ? fn.arguments : JSON.stringify(fn.arguments ?? {}),
      },
    };
  });
}

export class OllamaClient {
  private readonly baseUrl: string;
  private readonly fetchImpl: typeof fetch;
  private readonly sleep: (ms: number, signal?: AbortSignal) => Promise<void>;
  private readonly maxRetries: number;

  constructor(cfg: OllamaClientConfig) {
    this.baseUrl = cfg.baseUrl.replace(/\/+$/, "");
    this.fetchImpl = cfg.fetchImpl ?? fetch;
    this.sleep = cfg.sleep ?? abortableDelay;
    this.maxRetries = cfg.maxRetries ?? 2;
  }

  /** Не-стрим генерация (с опциональными tools). */
  async chat(req: OllamaChatRequest): Promise<OllamaChatResult> {
    const body = JSON.stringify({
      model: req.model,
      messages: req.messages,
      stream: false,
      keep_alive: req.keepAlive,
      tools: req.tools && req.tools.length > 0 ? req.tools : undefined,
      options: buildOptions(req.params),
    });
    const resp = await this.postWithRetry("/api/chat", body, req.signal);
    const raw = await resp.text();
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(raw);
    } catch {
      throw new UpstreamError("Некорректный JSON от Ollama");
    }
    const message = parsed.message as Record<string, unknown> | undefined;
    return {
      content: (message?.content as string) ?? "",
      toolCalls: toToolCallDTOs(message),
      usage: toUsage(parsed),
      timings: toTimings(parsed),
    };
  }

  /**
   * Стрим генерации: onDelta на каждый кусок текста; финальный объект (done:true)
   * даёт usage/timings. Ретраи ТОЛЬКО до первого байта тела.
   */
  async chatStream(
    req: OllamaChatRequest,
    onDelta: (text: string) => void,
  ): Promise<OllamaChatResult> {
    const body = JSON.stringify({
      model: req.model,
      messages: req.messages,
      stream: true,
      keep_alive: req.keepAlive,
      options: buildOptions(req.params),
    });
    const resp = await this.postWithRetry("/api/chat", body, req.signal);
    if (!resp.body) throw new UpstreamError("Пустой поток от Ollama");

    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let content = "";
    let usage: ChatUsage = { promptTokens: 0, completionTokens: 0 };
    let timings: ChatTimings = {
      loadDurationMs: 0,
      promptEvalDurationMs: 0,
      evalDurationMs: 0,
      tokensPerSecond: 0,
    };

    const handleLine = (line: string) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      let obj: Record<string, unknown>;
      try {
        obj = JSON.parse(trimmed);
      } catch {
        return; // неполная/битая строка — пропускаем
      }
      const msg = obj.message as { content?: string } | undefined;
      if (msg?.content) {
        content += msg.content;
        onDelta(msg.content);
      }
      if (obj.done === true) {
        usage = toUsage(obj);
        timings = toTimings(obj);
      }
    };

    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let nl: number;
        while ((nl = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, nl);
          buffer = buffer.slice(nl + 1);
          handleLine(line);
        }
      }
      if (buffer.trim()) handleLine(buffer);
    } catch (e) {
      if (isAbort(e, req.signal)) throw e;
      throw new UpstreamError(`Обрыв потока Ollama: ${(e as Error).message}`);
    }

    return { content, toolCalls: [], usage, timings };
  }

  /** Батч эмбеддингов (родной /api/embed). Порядок векторов = порядку текстов. */
  async embed(model: string, input: string[], signal?: AbortSignal): Promise<number[][]> {
    if (input.length === 0) return [];
    const body = JSON.stringify({ model, input });
    const resp = await this.postWithRetry("/api/embed", body, signal);
    const parsed = (await resp.json()) as { embeddings?: number[][] };
    const embeddings = parsed.embeddings ?? [];
    if (embeddings.length !== input.length) {
      throw new UpstreamError(
        `Ollama вернула ${embeddings.length} эмбеддингов на ${input.length} текстов`,
      );
    }
    return embeddings;
  }

  async listModels(): Promise<OllamaModelInfo[]> {
    const resp = await this.getWithRetry("/api/tags");
    const parsed = (await resp.json()) as { models?: Array<Record<string, unknown>> };
    return (parsed.models ?? []).map((m) => {
      const details = (m.details as Record<string, unknown> | undefined) ?? {};
      return {
        name: (m.name as string) ?? "",
        sizeBytes: (m.size as number) ?? null,
        parameterSize: (details.parameter_size as string) ?? null,
        quantization: (details.quantization_level as string) ?? null,
      };
    });
  }

  async ps(): Promise<OllamaLoadedModel[]> {
    const resp = await this.getWithRetry("/api/ps");
    const parsed = (await resp.json()) as { models?: Array<Record<string, unknown>> };
    return (parsed.models ?? []).map((m) => ({
      name: (m.name as string) ?? "",
      sizeBytes: (m.size as number) ?? null,
      expiresAt: (m.expires_at as string) ?? null,
    }));
  }

  async version(): Promise<string> {
    const resp = await this.getWithRetry("/api/version");
    const parsed = (await resp.json()) as { version?: string };
    return parsed.version ?? "";
  }

  /** Прогрев: загружает модель в память без генерации (пустые messages). */
  async warmup(model: string, keepAlive = "60m"): Promise<void> {
    const body = JSON.stringify({ model, messages: [], stream: false, keep_alive: keepAlive });
    await this.postWithRetry("/api/chat", body, undefined);
  }

  // ── Внутреннее: POST/GET с ретраями до первого байта тела ──────────────────

  private async postWithRetry(
    path: string,
    body: string,
    signal: AbortSignal | undefined,
  ): Promise<Response> {
    return this.sendWithRetry(path, { method: "POST", body }, signal);
  }

  private async getWithRetry(path: string): Promise<Response> {
    return this.sendWithRetry(path, { method: "GET" }, undefined);
  }

  private async sendWithRetry(
    path: string,
    init: { method: string; body?: string },
    signal: AbortSignal | undefined,
  ): Promise<Response> {
    const url = this.baseUrl + path;
    const headers: Record<string, string> = {};
    if (init.body) headers["Content-Type"] = "application/json";
    let lastError = "Сбой запроса к Ollama";
    for (let attempt = 0; attempt <= this.maxRetries; attempt++) {
      let resp: Response;
      try {
        resp = await this.fetchImpl(url, { method: init.method, headers, body: init.body, signal });
      } catch (e) {
        if (isAbort(e, signal)) throw e;
        lastError = `Ollama недоступна: ${(e as Error).message}`;
        if (attempt < this.maxRetries) {
          await this.backoff(attempt, signal);
          continue;
        }
        throw new UpstreamError(lastError);
      }
      if (resp.ok) return resp;

      const text = await resp.text().catch(() => "");
      if (RETRIABLE_STATUSES.has(resp.status) && attempt < this.maxRetries) {
        lastError = `Ollama вернула ${resp.status}: ${text}`;
        await this.backoff(attempt, signal);
        continue;
      }
      throw new UpstreamError(`Ollama вернула ${resp.status}: ${text || "ошибка"}`);
    }
    throw new UpstreamError(lastError);
  }

  private async backoff(attempt: number, signal?: AbortSignal): Promise<void> {
    const ms = Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * 2 ** attempt);
    await this.sleep(ms, signal);
  }
}
