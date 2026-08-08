// settingsRepo.ts — единственная строка настроек gateway (id = 1).
//
// Ключ LLM живёт здесь, а не в env: владелец меняет его из админки без
// передеплоя. Наружу ключ не отдаётся — только признак «задан» и последние 4
// символа (см. toPublic). Снисходительный декодер: битые/будущие значения → дефолт.

import type { DB } from "./db.js";
import type { TokenPrices } from "../cost/pricing.js";
import type { PolicyMode } from "../guard/inputGuard.js";
import {
  DEFAULT_SETTINGS,
  type GatewaySettings,
  type GatewaySettingsPublic,
} from "../domain/types.js";

function parsePolicy(raw: unknown): PolicyMode {
  return raw === "block" || raw === "mask" ? raw : DEFAULT_SETTINGS.inputPolicy;
}

function parsePrices(raw: unknown): Record<string, TokenPrices> {
  if (typeof raw !== "string" || !raw) return { ...DEFAULT_SETTINGS.prices };
  try {
    const obj = JSON.parse(raw);
    if (!obj || typeof obj !== "object") return { ...DEFAULT_SETTINGS.prices };
    const out: Record<string, TokenPrices> = {};
    for (const [model, p] of Object.entries(obj as Record<string, any>)) {
      const inp = Number(p?.inputPerMillion);
      const outp = Number(p?.outputPerMillion);
      if (Number.isFinite(inp) && Number.isFinite(outp)) {
        out[model] = { inputPerMillion: inp, outputPerMillion: outp };
      }
    }
    return Object.keys(out).length ? out : { ...DEFAULT_SETTINGS.prices };
  } catch {
    return { ...DEFAULT_SETTINGS.prices };
  }
}

function tail(secret: string): string {
  return secret.length >= 4 ? secret.slice(-4) : "";
}

export function toPublic(s: GatewaySettings): GatewaySettingsPublic {
  const { llmApiKey, ...rest } = s;
  return { ...rest, hasLlmKey: llmApiKey.length > 0, llmKeyTail: tail(llmApiKey) };
}

export class SettingsRepo {
  constructor(
    private readonly db: DB,
    private readonly now: () => Date = () => new Date(),
  ) {}

  get(): GatewaySettings {
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
      systemPrompt: String(row.system_prompt || DEFAULT_SETTINGS.systemPrompt),
      inputPolicy: parsePolicy(row.input_policy),
      prices: parsePrices(row.prices_json),
      rateLimitPerMin: Number(row.rate_limit_per_min ?? DEFAULT_SETTINGS.rateLimitPerMin),
      dailyLimit: Number(row.daily_limit ?? DEFAULT_SETTINGS.dailyLimit),
      updatedAt: String(row.updated_at ?? ""),
    };
  }

  /** Пустой ключ в patch не затирает сохранённый (write-only секрет). */
  update(patch: Partial<GatewaySettings>): GatewaySettings {
    const current = this.get();
    const next: GatewaySettings = {
      ...current,
      ...patch,
      llmApiKey: patch.llmApiKey ? patch.llmApiKey : current.llmApiKey,
      updatedAt: this.now().toISOString(),
    };
    this.db
      .prepare(
        `UPDATE settings SET llm_url = ?, llm_api_key = ?, model = ?, temperature = ?,
           max_tokens = ?, system_prompt = ?, input_policy = ?, prices_json = ?,
           rate_limit_per_min = ?, daily_limit = ?, updated_at = ?
         WHERE id = 1`,
      )
      .run(
        next.llmUrl,
        next.llmApiKey,
        next.model,
        next.temperature,
        next.maxTokens,
        next.systemPrompt,
        next.inputPolicy,
        JSON.stringify(next.prices),
        next.rateLimitPerMin,
        next.dailyLimit,
        next.updatedAt,
      );
    return next;
  }
}
