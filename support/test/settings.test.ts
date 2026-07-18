// Тесты настроек: write-only секрет, маскирование, клампы.

import { describe, expect, it } from "vitest";
import { openDb } from "../src/store/db.js";
import { SettingsRepo } from "../src/store/settingsRepo.js";
import { SettingsService, clampRag, maskSecret } from "../src/settings/settingsService.js";
import { DEFAULT_RAG_OPTIONS } from "../src/domain/types.js";
import { ValidationError } from "../src/domain/errors.js";

function makeService() {
  return new SettingsService(new SettingsRepo(openDb(":memory:")));
}

describe("SettingsService", () => {
  it("дефолты: провайдер ollama, промпт саппорта, RAG-параметры", () => {
    const s = makeService().getPublic();
    expect(s.provider).toBe("ollama");
    expect(s.hasLlmKey).toBe(false);
    expect(s.systemPrompt).toContain("Second Brain");
    expect(s.rag).toEqual(DEFAULT_RAG_OPTIONS);
  });

  it("секрет write-only: наружу только hint, пустой ключ не затирает", () => {
    const svc = makeService();
    const updated = svc.update({ llmApiKey: "sk-abcd1234" }, "t1");
    expect(updated.hasLlmKey).toBe(true);
    expect(updated.llmKeyHint).toBe("…1234");
    expect(JSON.stringify(updated)).not.toContain("sk-abcd1234");
    // Пустой ключ = «не менять».
    const after = svc.update({ llmApiKey: "", provider: "deepseek" }, "t2");
    expect(after.hasLlmKey).toBe(true);
    expect(svc.getInternal().llmApiKey).toBe("sk-abcd1234");
  });

  it("неизвестный провайдер отклоняется", () => {
    expect(() => makeService().update({ provider: "gpt" as never }, "t")).toThrow(ValidationError);
  });

  it("RAG-параметры клампятся, maxIterations в границах", () => {
    const svc = makeService();
    const s = svc.update(
      { rag: { topK: 999, minScore: -5 }, maxIterations: 100 },
      "t",
    );
    expect(s.rag.topK).toBe(20);
    expect(s.rag.minScore).toBe(0);
    expect(s.rag.candidateK).toBe(DEFAULT_RAG_OPTIONS.candidateK); // не тронут
    expect(s.maxIterations).toBe(10);
  });
});

describe("утилиты", () => {
  it("maskSecret", () => {
    expect(maskSecret("")).toBe("");
    expect(maskSecret("sk-abcd1234")).toBe("…1234");
  });

  it("clampRag не трогает непереданные поля", () => {
    const out = clampRag(DEFAULT_RAG_OPTIONS, { budgetTokens: 50 });
    expect(out.budgetTokens).toBe(100); // нижняя граница
    expect(out.topK).toBe(DEFAULT_RAG_OPTIONS.topK);
  });
});
