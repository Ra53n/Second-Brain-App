// chat.ts — доменные типы и дефолты чата поддержки (порт domain/chat.ts MA).
//
// Всё, что влияет на качество ответов маленькой CPU-модели, собрано здесь:
//   • numCtx — длина контекста (у Ollama дефолт 4096 молча режет диалог);
//   • maxTokens мал (CPU медленный, ~3–5 ток/с).
// В отличие от MA пресетов нет: системный промпт один (саппорт) и задаётся в
// настройках сервиса, а не per-чат.

/** Параметры генерации (мапятся в options родного /api/chat Ollama). */
export interface ChatParams {
  numCtx: number;
  temperature: number;
  topP: number;
  maxTokens: number; // → options.num_predict (НЕ max_tokens!)
  repeatPenalty?: number;
  seed?: number;
}

export interface ChatUsage {
  promptTokens: number;
  completionTokens: number;
}

/** Тайминги генерации (из наносекунд ответа Ollama) — для диагностики скорости. */
export interface ChatTimings {
  loadDurationMs: number;
  promptEvalDurationMs: number;
  evalDurationMs: number;
  tokensPerSecond: number;
}

export type ChatRole = "user" | "assistant";

export interface StoredChatMessage {
  id: string;
  sessionId: string;
  seq: number;
  role: ChatRole;
  content: string;
  usage?: ChatUsage;
  toolCalls?: Array<{ name: string; ok: boolean }>;
  createdAt: string;
}

export interface ChatSession {
  id: string;
  userId: string | null; // null — admin-пространство (bearer)
  title: string;
  ticketId: string; // "" — обращение в CRM ещё не создано
  createdAt: string;
  updatedAt: string;
}

export interface ChatSessionSummary {
  id: string;
  title: string;
  messageCount: number;
  createdAt: string;
  updatedAt: string;
}

// ── Дефолты ──────────────────────────────────────────────────────────────────

export const DEFAULT_NUM_CTX = 8192;
export const DEFAULT_CHAT_TEMPERATURE = 0.3; // саппорт: точность важнее креатива
export const DEFAULT_TOP_P = 0.95;
export const DEFAULT_CHAT_MAX_TOKENS = 1024; // CPU: держим ответ коротким
export const CHAT_KEEP_ALIVE = "60m"; // держим модель тёплой между сообщениями
export const CHAT_TIMEOUT_MS = 600_000; // 10 мин: prompt eval на CPU долгий
export const CHAT_QUEUE_MAX_WAITING = 4; // сверх исполняемого — очередь ожидания
export const CTX_SAFETY_MARGIN_TOKENS = 256; // запас на chat-template/погрешность

export const DEFAULT_CHAT_PARAMS: ChatParams = {
  numCtx: DEFAULT_NUM_CTX,
  temperature: DEFAULT_CHAT_TEMPERATURE,
  topP: DEFAULT_TOP_P,
  maxTokens: DEFAULT_CHAT_MAX_TOKENS,
};
