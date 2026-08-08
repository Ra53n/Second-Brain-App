// pricing.test.ts — расчёт стоимости запроса.

import { describe, it, expect } from "vitest";
import { computeCost, pricesFor, DEFAULT_PRICES, FALLBACK_PRICE } from "../src/cost/pricing.js";

describe("cost tracking", () => {
  it("стоимость = вход×тариф_in + выход×тариф_out", () => {
    const prices = { inputPerMillion: 0.27, outputPerMillion: 1.1 };
    const c = computeCost({ promptTokens: 1_000_000, completionTokens: 1_000_000, totalTokens: 2_000_000 }, prices);
    expect(c.inputUsd).toBeCloseTo(0.27, 6);
    expect(c.outputUsd).toBeCloseTo(1.1, 6);
    expect(c.usd).toBeCloseTo(1.37, 6);
  });

  it("малый расход считается точно", () => {
    const c = computeCost({ promptTokens: 1500, completionTokens: 500, totalTokens: 2000 }, {
      inputPerMillion: 0.27,
      outputPerMillion: 1.1,
    });
    expect(c.usd).toBeCloseTo(1500e-6 * 0.27 + 500e-6 * 1.1, 9);
  });

  it("pricesFor берёт тариф модели, иначе fallback", () => {
    expect(pricesFor("deepseek-v4-flash")).toEqual(DEFAULT_PRICES["deepseek-v4-flash"]);
    expect(pricesFor("неизвестная-модель")).toEqual(FALLBACK_PRICE);
  });
});
