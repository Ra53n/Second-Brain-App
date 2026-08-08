// pricing.ts — расчёт стоимости запроса по токенам (чистое ядро P1).
//
// Цены — за 1M токенов, отдельно вход/выход. Держим конфигурируемыми в
// настройках: тарифы DeepSeek меняются, хардкодить намертво нельзя.
// Cache-hit цены DeepSeek не моделируем (вне объёма задачи 103).

import type { Usage } from "../llm/openaiClient.js";

export interface TokenPrices {
  inputPerMillion: number;
  outputPerMillion: number;
}

/**
 * Дефолтные тарифы (USD за 1M токенов). ⚠️ Не сверены с актуальным прайсом
 * DeepSeek для линейки v4 — задаются в админке и правятся без передеплоя.
 * Неизвестная модель считается по FALLBACK_PRICE, стоимость тогда ориентировочна.
 */
export const DEFAULT_PRICES: Record<string, TokenPrices> = {
  "deepseek-v4-flash": { inputPerMillion: 0.27, outputPerMillion: 1.1 },
  "deepseek-v4-pro": { inputPerMillion: 0.55, outputPerMillion: 2.19 },
};

export const FALLBACK_PRICE: TokenPrices = { inputPerMillion: 0.27, outputPerMillion: 1.1 };

export function pricesFor(
  model: string,
  table: Record<string, TokenPrices> = DEFAULT_PRICES,
): TokenPrices {
  return table[model] ?? FALLBACK_PRICE;
}

export interface CostResult {
  usd: number;
  inputUsd: number;
  outputUsd: number;
}

/** Стоимость обмена в USD по расходу токенов и тарифу модели. */
export function computeCost(usage: Usage, prices: TokenPrices): CostResult {
  const inputUsd = (usage.promptTokens / 1_000_000) * prices.inputPerMillion;
  const outputUsd = (usage.completionTokens / 1_000_000) * prices.outputPerMillion;
  return { usd: inputUsd + outputUsd, inputUsd, outputUsd };
}
