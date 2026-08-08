// types.ts — доменные типы лаборатории.

/**
 * Уровень защиты. Переключается в админке, атакующему не показывается.
 * Смысл уровней — воспроизвести сравнение «до/после защиты» (задача 87):
 * на `easy` атаки должны проходить, на `hard` — нет.
 */
export type SecurityLevel = "easy" | "normal" | "hard";

export const SECURITY_LEVELS: SecurityLevel[] = ["easy", "normal", "hard"];

export function parseSecurityLevel(raw: unknown): SecurityLevel {
  // Неизвестное значение «из будущего» → самый строгий режим.
  return SECURITY_LEVELS.includes(raw as SecurityLevel) ? (raw as SecurityLevel) : "hard";
}

/** Провайдер веб-поиска. `none` — инструмент отвечает «не настроен». */
export type SearchProvider = "none" | "tavily" | "brave" | "serper";

export interface LabSettings {
  /** Базовый URL OpenAI-совместимого API (DeepSeek по умолчанию). */
  llmUrl: string;
  llmApiKey: string;
  model: string;
  temperature: number;
  maxTokens: number;
  maxIterations: number;
  securityLevel: SecurityLevel;
  searchProvider: SearchProvider;
  searchApiKey: string;
  /** Код доступа для атакующих (хеш scrypt; пустой = вход закрыт). */
  accessCodeHash: string;
  /** Суточный потолок обменов на весь сервис — защита от слива баланса. */
  dailyExchangeLimit: number;
  updatedAt: string;
}

/** Настройки без секретов — то, что можно отдать в админку. */
export interface LabSettingsPublic
  extends Omit<LabSettings, "llmApiKey" | "searchApiKey" | "accessCodeHash"> {
  hasLlmKey: boolean;
  llmKeyTail: string;
  hasSearchKey: boolean;
  searchKeyTail: string;
  hasAccessCode: boolean;
}

/** Ключи подсадных флагов. */
export type FlagKey = "prompt" | "corp" | "egress";

export const FLAG_KEYS: FlagKey[] = ["prompt", "corp", "egress"];

export interface Flag {
  key: FlagKey;
  value: string;
  createdAt: string;
}

/** Одна попытка = один обмен «сообщение атакующего → ответ агента». */
export interface Attempt {
  id: string;
  sessionId: string;
  createdAt: string;
  securityLevel: SecurityLevel;
  userText: string;
  answerText: string;
  /** Имена вызванных инструментов в порядке вызова. */
  tools: string[];
  /** Флаги, реально выданные агентом в этом обмене. */
  captured: FlagKey[];
  /** Что срезал egress-guard (для отчёта: «попытка была, но не прошла»). */
  blocked: string[];
}

export interface LabSession {
  id: string;
  label: string;
  createdAt: string;
  lastSeen: string;
}

export const DEFAULT_SETTINGS: LabSettings = {
  llmUrl: "https://api.deepseek.com/chat/completions",
  llmApiKey: "",
  model: "deepseek-chat",
  temperature: 0.3,
  maxTokens: 1200,
  maxIterations: 5,
  securityLevel: "normal",
  searchProvider: "none",
  searchApiKey: "",
  accessCodeHash: "",
  dailyExchangeLimit: 500,
  updatedAt: "",
};
