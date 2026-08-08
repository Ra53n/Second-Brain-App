// openaiClient.ts — OpenAI-совместимый клиент чата + агентный tool-loop
// (порт runner/llm.ts из manager-agent).
//
// Запрос с `tools` → если модель вернула tool_calls, исполняем их через
// `execute`, добавляем assistant+tool сообщения, повторяем до maxIterations;
// на последней итерации tools не передаются вовсе (форс финального текста).

import { UpstreamError } from "../domain/errors.js";

// ─── Типы сообщений/инструментов (формат OpenAI / DeepSeek) ──────────────────

export interface ToolCallDTO {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
}

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls?: ToolCallDTO[];
  tool_call_id?: string;
}

export interface ToolDef {
  type: "function";
  function: { name: string; description?: string; parameters: unknown };
}

export interface Usage {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
}

export interface ChatCompletion {
  message: { content: string | null; tool_calls?: ToolCallDTO[] };
  usage: Usage;
}

export interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  temperature: number;
  maxTokens: number;
  tools?: ToolDef[];
  toolChoice?: "auto" | "none";
  signal?: AbortSignal;
}

/** Абстракция вызова модели (HTTP ниже; ollamaToolAdapter — для локальной). */
export interface LlmCompletionClient {
  chat(req: ChatRequest): Promise<ChatCompletion>;
}

export interface ToolLoopResult {
  text: string;
  usage: Usage;
  transcript: Array<{ name: string; ok: boolean }>;
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

// ─── HTTP-реализация клиента (fetch) ─────────────────────────────────────────

export interface HttpLlmConfig {
  url: string;
  apiKey: string;
  /** Заголовок X-Title для OpenRouter (иначе не нужен). */
  appTitle?: string;
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
    const body: Record<string, unknown> = {
      model: req.model,
      messages: req.messages,
      stream: false,
      temperature: req.temperature,
      max_tokens: req.maxTokens,
    };
    if (req.tools && req.tools.length > 0) {
      body.tools = req.tools;
      body.tool_choice = req.toolChoice ?? "auto";
    }

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      Authorization: `Bearer ${this.cfg.apiKey}`,
    };
    if (this.cfg.appTitle) headers["X-Title"] = this.cfg.appTitle;
    const payload = JSON.stringify(body);

    // Транзиентные сбои переживаем повтором с экспоненциальным бэкоффом.
    // Отмену и клиентские 4xx НЕ ретраим.
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
        message: { content: choice.content ?? null, tool_calls: choice.tool_calls },
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

// ─── Агентный tool-loop ──────────────────────────────────────────────────────

export interface ToolLoopParams {
  client: LlmCompletionClient;
  model: string;
  temperature: number;
  maxTokens: number;
  messages: ChatMessage[];
  tools: ToolDef[];
  maxIterations: number;
  /** Исполнитель инструмента: возвращает текст; "ERROR..." при ошибке (НЕ бросает). */
  execute: (name: string, argsJSON: string) => Promise<string>;
  /** Колбэк перед исполнением инструмента (SSE-статус «вызываю …»). */
  onToolCall?: (name: string) => void;
  /** Мягкий бюджет токенов: при превышении форсируем финальный текстовый ответ. */
  maxTokensBudget?: number;
  signal?: AbortSignal;
}

/**
 * Ядро агентного цикла (порт runToolLoop MA). Возвращает финальный текст +
 * суммарный расход токенов + транскрипт вызовов инструментов.
 */
export async function runToolLoop(params: ToolLoopParams): Promise<ToolLoopResult> {
  const messages = [...params.messages];
  const usage: Usage = { promptTokens: 0, completionTokens: 0, totalTokens: 0 };
  const transcript: Array<{ name: string; ok: boolean }> = [];
  const maxIter = Math.max(1, params.maxIterations);
  const hasTools = params.tools.length > 0;

  for (let iter = 0; iter < maxIter; iter++) {
    const budgetExceeded =
      !!params.maxTokensBudget && usage.totalTokens >= params.maxTokensBudget;
    const isLast = iter === maxIter - 1 || budgetExceeded;

    // На последней итерации НЕ передаём tools вовсе: иначе модель может вернуть
    // служебную разметку tool-calls текстом вместо финального ответа. Плюс нудж
    // «синтезируй финал по собранным данным».
    const sendTools = hasTools && !isLast;
    const callMessages: ChatMessage[] = sendTools
      ? messages
      : [
          ...messages,
          {
            role: "user",
            content:
              "СТОП. Останови сбор данных и не вызывай инструменты. Выведи ПРЯМО СЕЙЧАС " +
              "только итоговый ответ пользователю по уже полученным выше данным. " +
              "Не описывай дальнейшие шаги — сразу финальный ответ.",
          },
        ];
    const resp = await params.client.chat({
      model: params.model,
      messages: callMessages,
      temperature: params.temperature,
      maxTokens: params.maxTokens,
      tools: sendTools ? params.tools : undefined,
      toolChoice: sendTools ? "auto" : undefined,
      signal: params.signal,
    });

    usage.promptTokens += resp.usage.promptTokens;
    usage.completionTokens += resp.usage.completionTokens;
    usage.totalTokens += resp.usage.totalTokens;

    const calls = resp.message.tool_calls ?? [];
    if (calls.length === 0 || isLast) {
      const text = stripModelMarkup(resp.message.content ?? "");
      if (!text) throw new UpstreamError("Пустой ответ от модели");
      return { text, usage, transcript };
    }

    // Модель просит инструменты: фиксируем её сообщение, исполняем, отвечаем.
    messages.push({ role: "assistant", content: resp.message.content, tool_calls: calls });
    for (const call of calls) {
      params.onToolCall?.(call.function.name);
      const out = await params.execute(call.function.name, call.function.arguments);
      transcript.push({ name: call.function.name, ok: !out.startsWith("ERROR") });
      messages.push({ role: "tool", content: out, tool_call_id: call.id });
    }
  }
  // Недостижимо (isLast обрабатывается выше), но TypeScript требует возврата.
  throw new UpstreamError("tool-loop завершился без ответа");
}
