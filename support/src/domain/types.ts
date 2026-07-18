// types.ts — доменные типы саппорт-ассистента.
//
// Контракт между сервером, админкой (SPA) и хранилищем. Новые поля добавлять
// опциональными/с дефолтами, чтобы старые записи в БД не падали (снисходительный
// декод — правило, унаследованное от manager-agent).

// ─── Провайдеры LLM ──────────────────────────────────────────────────────────

// ollama — локальная модель на VPS (native /api/chat); остальные — облачные
// OpenAI-совместимые API (ключ обязателен).
export const PROVIDERS = ["ollama", "deepseek", "openrouter"] as const;
export type Provider = (typeof PROVIDERS)[number];

/** Endpoint chat/completions облачного провайдера (как в Providers.swift MA). */
export function providerChatUrl(provider: "deepseek" | "openrouter"): string {
  switch (provider) {
    case "deepseek":
      return "https://api.deepseek.com/chat/completions";
    case "openrouter":
      return "https://openrouter.ai/api/v1/chat/completions";
  }
}

// ─── MCP-серверы ─────────────────────────────────────────────────────────────

/** Конфиг MCP-сервера (stdio: command+args+env). Содержит секреты в args/env. */
export interface McpServerConfig {
  id: string;
  name: string;
  command: string;
  args: string[];
  env: Record<string, string>;
  enabled: boolean;
}

/** Публичный статус MCP-сервера (БЕЗ секретов) для админки. */
export interface McpServerPublic {
  id: string;
  name: string;
  command: string;
  enabled: boolean;
  connected: boolean;
  toolCount: number;
  error?: string | null;
}

// ─── Настройки сервиса (одна строка в SQLite, id=1) ──────────────────────────

/** Параметры RAG-ретрива (кламп в settingsService). */
export interface RagOptions {
  topK: number;
  candidateK: number;
  minScore: number;
  budgetTokens: number;
}

export const DEFAULT_RAG_OPTIONS: RagOptions = {
  topK: 4,
  candidateK: 8,
  minScore: 0.4,
  budgetTokens: 1200,
};

/** Полные настройки С СЕКРЕТАМИ — только внутри сервера, наружу не отдаются. */
export interface SupportSettings {
  provider: Provider;
  llmApiKey: string;
  remoteModel: string;
  localModel: string;
  embedModel: string;
  systemPrompt: string;
  rag: RagOptions;
  maxIterations: number;
  updatedAt: string;
}

/** Публичное представление настроек: секрет замаскирован (write-only паттерн). */
export interface SupportSettingsPublic {
  provider: Provider;
  remoteModel: string;
  localModel: string;
  embedModel: string;
  systemPrompt: string;
  rag: RagOptions;
  maxIterations: number;
  hasLlmKey: boolean;
  llmKeyHint: string; // напр. "…ab12" или ""
  updatedAt: string;
}

/** Тело PATCH /support/admin/settings. Секрет применяется ТОЛЬКО если непустой. */
export interface UpdateSupportSettingsInput {
  provider?: Provider;
  llmApiKey?: string;
  remoteModel?: string;
  localModel?: string;
  embedModel?: string;
  systemPrompt?: string;
  rag?: Partial<RagOptions>;
  maxIterations?: number;
}

// ─── CRM (JSON-файлы на VPS; референс вместо реальной CRM) ───────────────────

export interface CrmUser {
  id: string;
  name: string;
  email: string;
  app_version: string;
  macos_version: string;
  registered_at: string;
  notes: string;
}

export const TICKET_STATUSES = ["open", "pending", "closed"] as const;
export type TicketStatus = (typeof TICKET_STATUSES)[number];

export interface TicketMessage {
  author: "user" | "support";
  text: string;
  at: string;
}

export interface CrmTicket {
  id: string;
  user_id: string;
  subject: string;
  status: TicketStatus;
  tags: string[];
  created_at: string;
  updated_at: string;
  messages: TicketMessage[];
}

// ─── Дефолты ─────────────────────────────────────────────────────────────────

export const DEFAULT_REMOTE_MODEL = "deepseek-chat";
export const DEFAULT_LOCAL_MODEL = "qwen3:4b-instruct-2507-q4_K_M";
export const DEFAULT_EMBED_MODEL = "bge-m3";
export const DEFAULT_MAX_ITERATIONS = 4;

/** Базовый системный промпт ассистента поддержки (редактируется в админке). */
export const DEFAULT_SUPPORT_SYSTEM_PROMPT =
  "Ты — ассистент поддержки пользователей приложения Second Brain (macOS-приложение " +
  "«второй мозг»: заметки, встречи с транскрипцией, чат по базе знаний, git-синхронизация). " +
  "Отвечай по-русски, вежливо, ясно и по существу. Опирайся ТОЛЬКО на фрагменты базы " +
  "знаний и данные клиента из контекста; если ответа там нет — честно скажи об этом и " +
  "предложи обратиться в поддержку, не выдумывай функции и шаги. Если у клиента есть " +
  "открытый тикет по теме вопроса — учитывай его содержимое в ответе и упомяни номер тикета. " +
  "В конце КАЖДОГО ответа отдельной строкой спроси, решило ли это вопрос пользователя, и " +
  "напомни, что кнопками под ответом можно отметить «решено» или передать обращение в поддержку.";
