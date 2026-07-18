// Тесты ретривера: порог, бюджет, guard-префикс, деградация при проблемах.

import { beforeEach, describe, expect, it } from "vitest";
import { openDb, type DB } from "../src/store/db.js";
import { KbRepo } from "../src/store/kbRepo.js";
import { KbIndexer } from "../src/rag/indexer.js";
import { HashingEmbedder, type Embedder } from "../src/rag/embedder.js";
import { NOT_FOUND_DIRECTIVE, buildBlock, retrieveBlock, searchKb } from "../src/rag/retriever.js";
import { DEFAULT_RAG_OPTIONS } from "../src/domain/types.js";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let db: DB;
let repo: KbRepo;
const embedder = new HashingEmbedder(64);

async function indexDocs(docs: Record<string, string>): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "kb-"));
  for (const [name, text] of Object.entries(docs)) {
    writeFileSync(join(dir, name), text, "utf8");
  }
  const indexer = new KbIndexer(repo, dir);
  await indexer.reindex(embedder);
}

beforeEach(() => {
  db = openDb(":memory:");
  repo = new KbRepo(db);
});

describe("searchKb", () => {
  it("находит релевантный чанк", async () => {
    await indexDocs({
      "faq.md": "# Авторизация git\nПри ошибке авторизации git push обновите токен GitHub.",
      "audio.md": "# Запись звука\nСистемный звук пишется через Core Audio process tap.",
    });
    const hits = await searchKb(repo, embedder, "не работает авторизация git push", 2);
    expect(hits.length).toBeGreaterThan(0);
    expect(hits[0]!.chunk.path).toBe("faq.md");
  });

  it("пустой индекс/пустой запрос → пусто", async () => {
    expect(await searchKb(repo, embedder, "вопрос", 3)).toEqual([]);
    await indexDocs({ "a.md": "# A\nтекст" });
    expect(await searchKb(repo, embedder, "   ", 3)).toEqual([]);
  });

  it("несовпадение embeddingTag (сменили модель) → пусто", async () => {
    await indexDocs({ "a.md": "# A\nтекст про авторизацию" });
    const other: Embedder = new HashingEmbedder(32); // другая размерность/модель
    expect(await searchKb(repo, other, "авторизация", 3)).toEqual([]);
  });

  it("ошибка эмбеддера → пусто, не исключение", async () => {
    await indexDocs({ "a.md": "# A\nтекст" });
    const broken: Embedder = {
      model: embedder.model,
      embed: async () => {
        throw new Error("embedder down");
      },
    };
    expect(await searchKb(repo, broken, "текст", 3)).toEqual([]);
  });
});

describe("retrieveBlock", () => {
  it("ничего не нашлось → NOT_FOUND_DIRECTIVE", async () => {
    const res = await retrieveBlock(repo, embedder, "вопрос", DEFAULT_RAG_OPTIONS);
    expect(res.block).toBe(NOT_FOUND_DIRECTIVE);
    expect(res.sources).toEqual([]);
  });

  it("порог minScore отсекает нерелевантное", async () => {
    await indexDocs({ "a.md": "# Совсем другое\nогурцы помидоры дача" });
    const res = await retrieveBlock(repo, embedder, "git push авторизация токен", {
      ...DEFAULT_RAG_OPTIONS,
      minScore: 0.9,
    });
    expect(res.block).toBe(NOT_FOUND_DIRECTIVE);
  });

  it("найденное — с guard-префиксом и источниками", async () => {
    await indexDocs({
      "faq.md": "# Авторизация\nПри ошибке авторизации git push обновите токен GitHub в Keychain.",
    });
    const res = await retrieveBlock(repo, embedder, "ошибка авторизации git push токен", {
      ...DEFAULT_RAG_OPTIONS,
      minScore: 0,
    });
    expect(res.block).toContain("СПРАВОЧНЫЕ ДАННЫЕ");
    expect(res.block).toContain("[источник: faq.md · Авторизация]");
    expect(res.sources[0]!.path).toBe("faq.md");
  });
});

describe("buildBlock", () => {
  const hit = (text: string, path = "f.md") => ({
    chunk: { id: 1, path, section: "S", ordinal: 0, text },
    score: 0.9,
  });

  it("лучший чанк включается всегда, даже сверх бюджета", () => {
    const block = buildBlock([hit("х".repeat(9000))], 10);
    expect(block).not.toBeNull();
    expect(block).toContain("х".repeat(100));
  });

  it("бюджет режет по границе чанка", () => {
    const block = buildBlock([hit("a".repeat(600), "1.md"), hit("b".repeat(600), "2.md")], 250);
    expect(block).toContain("1.md");
    expect(block).not.toContain("2.md");
  });

  it("пустые хиты → null", () => {
    expect(buildBlock([], 100)).toBeNull();
    expect(buildBlock([hit("   ")], 100)).toBeNull();
  });
});
