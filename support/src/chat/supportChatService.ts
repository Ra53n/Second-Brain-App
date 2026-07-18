// supportChatService.ts — ядро ассистента поддержки: сборка системного промпта
// (базовый промпт + CRM-контекст клиента + RAG-блок по вопросу), очередь
// (локальная модель обслуживает по одному), выбор провайдера и tool-loop.
//
// Порт chatService.ts MA (estimateTokens/assembleMessages/FifoGate) + новая
// оркестрация. Стриминг-компромисс для слабого VPS (зафиксирован в задаче 38):
//   • есть MCP-инструменты → runToolLoop БЕЗ стрима токенов; onStatus шлёт
//     «вызываю <tool>…», финальный текст отдаётся одним куском;
//   • инструментов нет и провайдер ollama → честный токен-стрим chatStream.

import { BusyError, ValidationError } from "../domain/errors.js";
import {
  CHAT_KEEP_ALIVE,
  CHAT_QUEUE_MAX_WAITING,
  CHAT_TIMEOUT_MS,
  CTX_SAFETY_MARGIN_TOKENS,
  DEFAULT_CHAT_PARAMS,
  type ChatRole,
  type ChatTimings,
  type ChatUsage,
} from "../domain/chat.js";
import type { SupportSettings } from "../domain/types.js";
import { providerChatUrl } from "../domain/types.js";
import type { SettingsService } from "../settings/settingsService.js";
import type { OllamaChatMessage, OllamaClient } from "../llm/ollamaClient.js";
import {
  HttpLlmClient,
  runToolLoop,
  type ChatMessage,
  type LlmCompletionClient,
  type ToolDef,
} from "../llm/openaiClient.js";
import { OllamaToolAdapter } from "../llm/ollamaToolAdapter.js";
import type { McpHost } from "../mcp/mcpHost.js";
import type { KbRepo } from "../store/kbRepo.js";
import { OllamaEmbedder, type Embedder } from "../rag/embedder.js";
import { retrieveBlock, type KbSource } from "../rag/retriever.js";
import type { CrmStore } from "../crm/crmStore.js";
import { buildCustomerContext } from "../crm/context.js";

/**
 * Консервативная оценка токенов: ~4 байта/токен (у qwen реально 5–6 — мы
 * ПЕРЕоцениваем, безопасная сторона) + запас на chat-template.
 */
export function estimateTokens(text: string): number {
  return Math.ceil(Buffer.byteLength(text, "utf8") / 4) + 8;
}

export interface HistoryMessage {
  role: ChatRole;
  content: string;
}

export interface AssembleResult {
  messages: OllamaChatMessage[];
  droppedCount: number;
}

/**
 * Собирает сообщения под бюджет контекста. Инварианты:
 *   • системный промпт — всегда первый и НЕ выкидывается;
 *   • последнее сообщение пользователя — НЕ выкидывается;
 *   • при нехватке места выкидываются САМЫЕ СТАРЫЕ сообщения.
 * Если системный промпт + последнее сообщение сами не влезают — 400.
 */
export function assembleMessages(input: {
  systemPrompt: string;
  history: HistoryMessage[];
  numCtx: number;
  maxTokens: number;
}): AssembleResult {
  const { systemPrompt, history, numCtx, maxTokens } = input;
  const budget = numCtx - maxTokens - CTX_SAFETY_MARGIN_TOKENS;

  const sysMsg: OllamaChatMessage[] = systemPrompt
    ? [{ role: "system", content: systemPrompt }]
    : [];
  const sysCost = systemPrompt ? estimateTokens(systemPrompt) : 0;

  if (history.length === 0) {
    if (sysCost > budget) {
      throw new ValidationError("Системный промпт длиннее контекстного окна.");
    }
    return { messages: sysMsg, droppedCount: 0 };
  }

  const last = history[history.length - 1]!;
  const lastCost = estimateTokens(last.content);
  if (sysCost + lastCost > budget) {
    throw new ValidationError(
      "Сообщение слишком длинное для контекстного окна — сократите его.",
    );
  }

  // Идём от конца к началу, добираем самые свежие сообщения, пока влезают.
  const kept: HistoryMessage[] = [last];
  let used = sysCost + lastCost;
  for (let i = history.length - 2; i >= 0; i--) {
    const cost = estimateTokens(history[i]!.content);
    if (used + cost > budget) break;
    used += cost;
    kept.unshift(history[i]!);
  }

  const droppedCount = history.length - kept.length;
  const messages: OllamaChatMessage[] = [
    ...sysMsg,
    ...kept.map((m) => ({ role: m.role, content: m.content })),
  ];
  return { messages, droppedCount };
}

// ── Очередь: локальная модель обслуживает по одному запросу ──────────────────

/**
 * FIFO-семафор с ёмкостью 1 и ограниченной очередью ожидания. Сверх maxWaiting —
 * синхронный BusyError (429). Отмена ожидающего освобождает слот.
 */
export class FifoGate {
  private active = false;
  private readonly waiters: Array<{
    resolve: () => void;
    reject: (e: unknown) => void;
    signal?: AbortSignal;
    onAbort?: () => void;
  }> = [];

  constructor(private readonly maxWaiting = CHAT_QUEUE_MAX_WAITING) {}

  stats(): { active: number; waiting: number } {
    return { active: this.active ? 1 : 0, waiting: this.waiters.length };
  }

  /** Ждёт слот; возвращает release(). Бросает BusyError при переполнении очереди. */
  async acquire(signal?: AbortSignal): Promise<() => void> {
    if (!this.active) {
      this.active = true;
      return () => this.release();
    }
    if (this.waiters.length >= this.maxWaiting) {
      throw new BusyError("Ассистент занят обработкой других запросов. Повторите чуть позже.");
    }
    await new Promise<void>((resolve, reject) => {
      const waiter = { resolve, reject, signal } as (typeof this.waiters)[number];
      if (signal) {
        waiter.onAbort = () => {
          const idx = this.waiters.indexOf(waiter);
          if (idx >= 0) this.waiters.splice(idx, 1);
          reject(new DOMException("Aborted", "AbortError"));
        };
        if (signal.aborted) return waiter.onAbort();
        signal.addEventListener("abort", waiter.onAbort, { once: true });
      }
      this.waiters.push(waiter);
    });
    return () => this.release();
  }

  private release(): void {
    const next = this.waiters.shift();
    if (next) {
      if (next.signal && next.onAbort) next.signal.removeEventListener("abort", next.onAbort);
      // active остаётся true — слот сразу переходит следующему.
      next.resolve();
    } else {
      this.active = false;
    }
  }
}

// ── Оркестрация ответа ───────────────────────────────────────────────────────

export interface AnswerInput {
  /** История диалога, включая ПОСЛЕДНИЙ вопрос пользователя. */
  history: HistoryMessage[];
  /** email логин-аккаунта для CRM-контекста (null — без привязки). */
  userEmail: string | null;
  /** Токен-стрим (только для пути без инструментов на ollama). */
  onDelta?: (text: string) => void;
  /** Статусы хода работы («ищу в базе знаний», «вызываю crm__get_ticket»). */
  onStatus?: (status: string) => void;
  signal?: AbortSignal;
}

export interface AnswerResult {
  content: string;
  usage: ChatUsage;
  timings: ChatTimings | null;
  toolCalls: Array<{ name: string; ok: boolean }>;
  sources: KbSource[];
  droppedCount: number;
}

/** Условный numCtx для бюджетирования истории у облачных моделей. */
const REMOTE_CTX_TOKENS = 32768;

export interface SupportChatDeps {
  settings: SettingsService;
  ollama: OllamaClient;
  kbRepo: KbRepo;
  crm: CrmStore;
  mcpHost: McpHost;
}

export interface SupportChatOpts {
  gate?: FifoGate;
  timeoutMs?: number;
  /** Фабрика клиента облачного провайдера (в тестах — заглушка). */
  remoteClientFactory?: (s: SupportSettings) => LlmCompletionClient;
  /** Фабрика эмбеддера (в тестах — HashingEmbedder). */
  embedderFactory?: (s: SupportSettings) => Embedder;
}

export class SupportChatService {
  private readonly gate: FifoGate;
  private readonly timeoutMs: number;
  private readonly remoteClientFactory: (s: SupportSettings) => LlmCompletionClient;
  private readonly embedderFactory: (s: SupportSettings) => Embedder;

  constructor(
    private readonly deps: SupportChatDeps,
    opts: SupportChatOpts = {},
  ) {
    this.gate = opts.gate ?? new FifoGate();
    this.timeoutMs = opts.timeoutMs ?? CHAT_TIMEOUT_MS;
    this.remoteClientFactory =
      opts.remoteClientFactory ??
      ((s) =>
        new HttpLlmClient({
          url: providerChatUrl(s.provider as "deepseek" | "openrouter"),
          apiKey: s.llmApiKey,
          appTitle: s.provider === "openrouter" ? "Second Brain — support assistant" : undefined,
        }));
    this.embedderFactory =
      opts.embedderFactory ?? ((s) => new OllamaEmbedder(this.deps.ollama, s.embedModel));
  }

  queueStats(): { active: number; waiting: number } {
    return this.gate.stats();
  }

  /** Системный промпт: базовый + CRM-контекст + RAG-блок. Возвращает и источники. */
  async buildSystemPrompt(
    settings: SupportSettings,
    userEmail: string | null,
    query: string,
  ): Promise<{ systemPrompt: string; sources: KbSource[] }> {
    const parts: string[] = [settings.systemPrompt];

    if (userEmail) {
      const crmBlock = buildCustomerContext(this.deps.crm, userEmail);
      if (crmBlock) parts.push(crmBlock);
    }

    const embedder = this.embedderFactory(settings);
    const rag = await retrieveBlock(this.deps.kbRepo, embedder, query, settings.rag);
    parts.push(rag.block);

    return { systemPrompt: parts.join("\n\n"), sources: rag.sources };
  }

  /**
   * Полный ответ ассистента: промпт → очередь → провайдер (+tool-loop) под
   * таймаутом. Бросает ValidationError(400)/BusyError(429)/UpstreamError(502).
   */
  async answer(input: AnswerInput): Promise<AnswerResult> {
    const settings = this.deps.settings.getInternal();
    if (settings.provider !== "ollama" && !settings.llmApiKey) {
      throw new ValidationError(
        `Провайдер ${settings.provider} требует API-ключ — задайте его в админке.`,
      );
    }
    const lastUser = input.history[input.history.length - 1];
    if (!lastUser || lastUser.role !== "user") {
      throw new ValidationError("История должна заканчиваться сообщением пользователя.");
    }

    input.onStatus?.("Ищу ответ в базе знаний…");
    const { systemPrompt, sources } = await this.buildSystemPrompt(
      settings,
      input.userEmail,
      lastUser.content,
    );

    const isLocal = settings.provider === "ollama";
    const model = isLocal ? settings.localModel : settings.remoteModel;
    const params = { ...DEFAULT_CHAT_PARAMS };
    const { messages, droppedCount } = assembleMessages({
      systemPrompt,
      history: input.history,
      numCtx: isLocal ? params.numCtx : REMOTE_CTX_TOKENS,
      maxTokens: params.maxTokens,
    });

    const tools: ToolDef[] = this.deps.mcpHost.availableTools().map((t) => ({
      type: "function",
      function: {
        name: t.qualifiedName,
        description: t.description,
        parameters: t.inputSchema ?? { type: "object", properties: {} },
      },
    }));

    const release = await this.gate.acquire(input.signal);
    // Таймаут генерации: свой AbortController, связанный с внешним signal.
    const ac = new AbortController();
    const onExternalAbort = () => ac.abort();
    input.signal?.addEventListener("abort", onExternalAbort, { once: true });
    const timer = setTimeout(() => ac.abort(), this.timeoutMs);
    try {
      // Путь без инструментов на локальной модели — честный токен-стрим.
      if (isLocal && tools.length === 0 && input.onDelta) {
        const res = await this.deps.ollama.chatStream(
          { model, messages, params, keepAlive: CHAT_KEEP_ALIVE, signal: ac.signal },
          input.onDelta,
        );
        return {
          content: res.content,
          usage: res.usage,
          timings: res.timings,
          toolCalls: [],
          sources,
          droppedCount,
        };
      }

      // Общий путь: tool-loop (или один вызов, если инструментов нет).
      const client: LlmCompletionClient = isLocal
        ? new OllamaToolAdapter(this.deps.ollama, {
            numCtx: params.numCtx,
            topP: params.topP,
            keepAlive: CHAT_KEEP_ALIVE,
          })
        : this.remoteClientFactory(settings);

      const loopMessages: ChatMessage[] = messages.map((m) => ({
        role: m.role,
        content: m.content,
      }));
      const result = await runToolLoop({
        client,
        model,
        temperature: params.temperature,
        maxTokens: params.maxTokens,
        messages: loopMessages,
        tools,
        maxIterations: tools.length > 0 ? settings.maxIterations : 1,
        execute: (name, argsJSON) => this.deps.mcpHost.call(name, argsJSON),
        onToolCall: (name) => input.onStatus?.(`Вызываю инструмент ${name}…`),
        signal: ac.signal,
      });
      input.onDelta?.(result.text);
      return {
        content: result.text,
        usage: {
          promptTokens: result.usage.promptTokens,
          completionTokens: result.usage.completionTokens,
        },
        timings: null,
        toolCalls: result.transcript,
        sources,
        droppedCount,
      };
    } finally {
      clearTimeout(timer);
      input.signal?.removeEventListener("abort", onExternalAbort);
      release();
    }
  }
}
