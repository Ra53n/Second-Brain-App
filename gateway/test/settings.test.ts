// settings.test.ts — снисходительный декодер настроек: битые/будущие значения
// → дефолт (заявленный инвариант P2), плюс write-only ключ.

import { describe, it, expect } from "vitest";
import { openDb } from "../src/store/db.js";
import { SettingsRepo, toPublic } from "../src/store/settingsRepo.js";
import { DEFAULT_SETTINGS } from "../src/domain/types.js";

function repo() {
  return new SettingsRepo(openDb(":memory:"));
}

describe("SettingsRepo — декодер и секреты", () => {
  it("невалидная политика в БД → дефолт", () => {
    const db = openDb(":memory:");
    db.prepare("UPDATE settings SET input_policy = 'из-будущего' WHERE id = 1").run();
    expect(new SettingsRepo(db).get().inputPolicy).toBe(DEFAULT_SETTINGS.inputPolicy);
  });

  it("битый prices_json → дефолтные тарифы", () => {
    const db = openDb(":memory:");
    db.prepare("UPDATE settings SET prices_json = '{битый' WHERE id = 1").run();
    expect(new SettingsRepo(db).get().prices).toEqual(DEFAULT_SETTINGS.prices);
  });

  it("prices с нечисловым тарифом отбрасывается → дефолт", () => {
    const db = openDb(":memory:");
    db.prepare("UPDATE settings SET prices_json = ? WHERE id = 1").run(
      JSON.stringify({ "x": { inputPerMillion: "дорого", outputPerMillion: 1 } }),
    );
    expect(new SettingsRepo(db).get().prices).toEqual(DEFAULT_SETTINGS.prices);
  });

  it("валидные prices сохраняются и читаются", () => {
    const r = repo();
    r.update({ prices: { "m": { inputPerMillion: 1, outputPerMillion: 2 } } });
    expect(r.get().prices).toEqual({ "m": { inputPerMillion: 1, outputPerMillion: 2 } });
  });

  it("пустой llmApiKey в update не затирает сохранённый ключ", () => {
    const r = repo();
    r.update({ llmApiKey: "sk-secret-123456" });
    r.update({ llmApiKey: "", model: "deepseek-reasoner" });
    expect(r.get().llmApiKey).toBe("sk-secret-123456");
    expect(r.get().model).toBe("deepseek-reasoner");
  });

  it("toPublic не отдаёт сам ключ, только признак и хвост", () => {
    const r = repo();
    r.update({ llmApiKey: "sk-abcdef-TAIL" });
    const pub = toPublic(r.get()) as Record<string, unknown>;
    expect(pub.llmApiKey).toBeUndefined();
    expect(pub.hasLlmKey).toBe(true);
    expect(pub.llmKeyTail).toBe("TAIL");
  });
});
