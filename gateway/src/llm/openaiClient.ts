// openaiClient.ts — OpenAI-совместимый клиент чата (порт из agent-lab).
//
// Ядро прокси gateway: реальный fetch на DeepSeek с ретраями транзиентных
// сбоев и экспоненциальным бэкоффом. Отмену и клиентские 4xx не ретраим.

import { UpstreamError } from "../domain/errors.js";

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
}

export interface Usage {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
}

export interface ChatCompletion {
  message: { content: string | null };
  usage: Usage;
}

export interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  temperature: number;
  maxTokens: number;
  signal?: AbortSignal;
}

export interface LlmCompletionClient {
  chat(req: ChatRequest): Promise<ChatCompletion>;
}

/**
 * Срезает служебную разметку модели, иногда протекающую в текст ответа
 * (DeepSeek DSML / tool-call токены `<｜…｜>`).
 */
export function stripModelMarkup(s: string): string {
  const idx = s.search(/<\s*[｜|]+\s*(DSML|tool)/i);
  const cut = idx >= 0 ? s.slice(0, idx) : s;
  return cut.replace(/<\s*[｜|]+[^>]*[｜|]+\s*>/g, "").trim();
}

export interface HttpLlmConfig {
  url: string;
  apiKey: string;
  /** Число ПОВТОРОВ (сверх первой попытки) при транзиентных сбоях. По умолчанию 3. */
  maxRetries?: number;
  /** Внедряемый fetch (для тестов); по умолчанию глобальный fetch. */
  fetchImpl?: typeof fetch;
  /** Внедряемая пауза бэкоффа (для тестов — мгновенная). */
  sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
}

const RETRIABLE_STATUSES = new Set([408, 409, 425, 429, 500, 502, 503, 504]);
const BACKOFF_BASE_MS = 500;
const BACKOFF_CAP_MS = 8000;

/** Пауза, прерываемая по AbortSignal. */
export function abortableDelay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new DOMException("Aborted", "AbortError"));
    const timer = setTimeout(() => {
      cleanup();
      resolve();
    }, ms);
    const onAbort = () => {
      cleanup();
      reject(new DOMException("Aborted", "AbortError"));
    };
    const cleanup = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function isAbort(e: unknown, signal?: AbortSignal): boolean {
  return !!signal?.aborted || (e instanceof Error && e.name === "AbortError");
}

export class HttpLlmClient implements LlmCompletionClient {
  private readonly maxRetries: number;
  private readonly fetchImpl: typeof fetch;
  private readonly sleep: (ms: number, signal?: AbortSignal) => Promise<void>;

  constructor(private readonly cfg: HttpLlmConfig) {
    this.maxRetries = cfg.maxRetries ?? 3;
    this.fetchImpl = cfg.fetchImpl ?? fetch;
    this.sleep = cfg.sleep ?? abortableDelay;
  }

  async chat(req: ChatRequest): Promise<ChatCompletion> {
    const body = {
      model: req.model,
      messages: req.messages,
      stream: false,
      temperature: req.temperature,
      max_tokens: req.maxTokens,
    };
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      Authorization: `Bearer ${this.cfg.apiKey}`,
    };
    const payload = JSON.stringify(body);

    let lastError = "Сбой запроса к LLM";
    for (let attempt = 0; attempt <= this.maxRetries; attempt++) {
      let resp: Response;
      try {
        resp = await this.fetchImpl(this.cfg.url, {
          method: "POST",
          headers,
          body: payload,
          signal: req.signal,
        });
      } catch (e) {
        if (isAbort(e, req.signal)) throw e;
        lastError = `Сбой запроса к LLM: ${(e as Error).message}`;
        if (attempt < this.maxRetries) {
          await this.backoff(attempt, null, req.signal);
          continue;
        }
        throw new UpstreamError(lastError);
      }

      const raw = await resp.text();
      if (!resp.ok) {
        let message = raw;
        try {
          message = JSON.parse(raw)?.error?.message ?? raw;
        } catch {
          /* оставляем raw */
        }
        if (RETRIABLE_STATUSES.has(resp.status) && attempt < this.maxRetries) {
          lastError = `Ошибка LLM (${resp.status}): ${message}`;
          await this.backoff(attempt, resp.headers.get("retry-after"), req.signal);
          continue;
        }
        throw new UpstreamError(`Ошибка LLM (${resp.status}): ${message}`);
      }

      let parsed: any;
      try {
        parsed = JSON.parse(raw);
      } catch {
        throw new UpstreamError("Некорректный JSON от LLM");
      }
      const choice = parsed?.choices?.[0]?.message;
      if (!choice) throw new UpstreamError("Пустой ответ от LLM (нет choices)");
      const u = parsed?.usage ?? {};
      return {
        message: { content: choice.content ?? null },
        usage: {
          promptTokens: u.prompt_tokens ?? 0,
          completionTokens: u.completion_tokens ?? 0,
          totalTokens: u.total_tokens ?? 0,
        },
      };
    }
    throw new UpstreamError(lastError);
  }

  /** Пауза перед повтором: max(экспонента, Retry-After). Прерывается отменой. */
  private async backoff(attempt: number, retryAfter: string | null, signal?: AbortSignal): Promise<void> {
    let ms = Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * 2 ** attempt);
    const ra = retryAfter ? Number.parseInt(retryAfter, 10) : NaN;
    if (Number.isFinite(ra) && ra > 0) ms = Math.max(ms, Math.min(BACKOFF_CAP_MS * 4, ra * 1000));
    await this.sleep(ms, signal);
  }
}
