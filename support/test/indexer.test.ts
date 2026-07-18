// Тесты индексера: транзакционная замена, embeddingTag, статусы, конкурентность.

import { describe, expect, it } from "vitest";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "../src/store/db.js";
import { KbRepo } from "../src/store/kbRepo.js";
import { KbIndexer } from "../src/rag/indexer.js";
import { HashingEmbedder } from "../src/rag/embedder.js";
import { ConflictError } from "../src/domain/errors.js";

function setup(docs: Record<string, string>) {
  const dir = mkdtempSync(join(tmpdir(), "kb-idx-"));
  for (const [name, text] of Object.entries(docs)) writeFileSync(join(dir, name), text, "utf8");
  const db = openDb(":memory:");
  const repo = new KbRepo(db);
  const indexer = new KbIndexer(repo, dir, () => new Date("2026-07-18T10:00:00Z"));
  return { dir, repo, indexer };
}

describe("KbIndexer", () => {
  it("индексирует .md файлы и пишет мету", async () => {
    const { repo, indexer } = setup({
      "a.md": "# A\nтекст один",
      "b.md": "# B\nтекст два",
      "ignore.txt": "не markdown",
    });
    const { chunkCount } = await indexer.reindex(new HashingEmbedder(64));
    expect(chunkCount).toBe(2);
    const meta = repo.getMeta();
    expect(meta.status).toBe("ready");
    expect(meta.chunkCount).toBe(2);
    expect(meta.embeddingTag).toBe("hashing-64|64");
    expect(meta.updatedAt).toBe("2026-07-18T10:00:00.000Z");
    const { chunks, vectors } = repo.loadAll();
    expect(chunks).toHaveLength(2);
    expect(vectors[0]!.length).toBe(64);
  });

  it("повторная индексация полностью заменяет старый индекс", async () => {
    const { dir, repo, indexer } = setup({ "a.md": "# A\nстарый текст" });
    await indexer.reindex(new HashingEmbedder(64));
    writeFileSync(join(dir, "a.md"), "# A\nновый текст\n# B\nвторой раздел", "utf8");
    await indexer.reindex(new HashingEmbedder(64));
    const { chunks } = repo.loadAll();
    expect(chunks).toHaveLength(2);
    expect(chunks.map((c) => c.text).join(" ")).toContain("новый");
  });

  it("ошибка эмбеддера → status=error + lastError", async () => {
    const { repo, indexer } = setup({ "a.md": "# A\nтекст" });
    const broken = {
      model: "broken",
      embed: async () => {
        throw new Error("нет сети");
      },
    };
    await expect(indexer.reindex(broken)).rejects.toThrow("нет сети");
    const meta = repo.getMeta();
    expect(meta.status).toBe("error");
    expect(meta.lastError).toContain("нет сети");
  });

  it("конкурентный запуск → ConflictError", async () => {
    const { indexer } = setup({ "a.md": "# A\nтекст" });
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const slow = {
      model: "slow",
      embed: async (texts: string[]) => {
        await gate;
        return texts.map(() => new Float32Array(8));
      },
    };
    const first = indexer.reindex(slow);
    await expect(indexer.reindex(new HashingEmbedder(8))).rejects.toThrow(ConflictError);
    release();
    await first;
  });
});
