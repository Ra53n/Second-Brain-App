// settingsRepo.ts — единственная строка настроек лаборатории (id = 1).
//
// Секреты (ключ LLM, ключ поиска, хеш кода доступа) живут здесь, а не в env:
// владелец меняет их из админки без передеплоя. Наружу они не отдаются никогда —
// только признак «задан» и последние 4 символа (см. toPublic).

import type { DB } from "./db.js";
import {
  DEFAULT_SETTINGS,
  parseSecurityLevel,
  type LabSettings,
  type LabSettingsPublic,
  type SearchProvider,
} from "../domain/types.js";

const SEARCH_PROVIDERS: SearchProvider[] = ["none", "tavily", "brave", "serper"];

function parseSearchProvider(raw: unknown): SearchProvider {
  return SEARCH_PROVIDERS.includes(raw as SearchProvider) ? (raw as SearchProvider) : "none";
}

function tail(secret: string): string {
  return secret.length >= 4 ? secret.slice(-4) : "";
}

export function toPublic(s: LabSettings): LabSettingsPublic {
  const { llmApiKey, searchApiKey, accessCodeHash, ...rest } = s;
  return {
    ...rest,
    hasLlmKey: llmApiKey.length > 0,
    llmKeyTail: tail(llmApiKey),
    hasSearchKey: searchApiKey.length > 0,
    searchKeyTail: tail(searchApiKey),
    hasAccessCode: accessCodeHash.length > 0,
  };
}

export class SettingsRepo {
  constructor(
    private readonly db: DB,
    private readonly now: () => Date = () => new Date(),
  ) {}

  get(): LabSettings {
    const row = this.db.prepare("SELECT * FROM settings WHERE id = 1").get() as
      | Record<string, unknown>
      | undefined;
    if (!row) return { ...DEFAULT_SETTINGS };
    return {
      llmUrl: String(row.llm_url ?? DEFAULT_SETTINGS.llmUrl),
      llmApiKey: String(row.llm_api_key ?? ""),
      model: String(row.model ?? DEFAULT_SETTINGS.model),
      temperature: Number(row.temperature ?? DEFAULT_SETTINGS.temperature),
      maxTokens: Number(row.max_tokens ?? DEFAULT_SETTINGS.maxTokens),
      maxIterations: Number(row.max_iterations ?? DEFAULT_SETTINGS.maxIterations),
      securityLevel: parseSecurityLevel(row.security_level),
      searchProvider: parseSearchProvider(row.search_provider),
      searchApiKey: String(row.search_api_key ?? ""),
      accessCodeHash: String(row.access_code_hash ?? ""),
      dailyExchangeLimit: Number(row.daily_exchange_limit ?? DEFAULT_SETTINGS.dailyExchangeLimit),
      updatedAt: String(row.updated_at ?? ""),
    };
  }

  /** Пустые/undefined-поля не затирают сохранённые секреты. */
  update(patch: Partial<LabSettings>): LabSettings {
    const current = this.get();
    const next: LabSettings = {
      ...current,
      ...patch,
      updatedAt: this.now().toISOString(),
    };
    this.db
      .prepare(
        `UPDATE settings SET llm_url = ?, llm_api_key = ?, model = ?, temperature = ?,
           max_tokens = ?, max_iterations = ?, security_level = ?, search_provider = ?,
           search_api_key = ?, access_code_hash = ?, daily_exchange_limit = ?, updated_at = ?
         WHERE id = 1`,
      )
      .run(
        next.llmUrl,
        next.llmApiKey,
        next.model,
        next.temperature,
        next.maxTokens,
        next.maxIterations,
        next.securityLevel,
        next.searchProvider,
        next.searchApiKey,
        next.accessCodeHash,
        next.dailyExchangeLimit,
        next.updatedAt,
      );
    return next;
  }
}
