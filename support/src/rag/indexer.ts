// indexer.ts — переиндексация базы знаний: скан *.md в KB_DIR → чанкинг →
// эмбеддинг батчами → транзакционная замена индекса в SQLite.
//
// Конкурентный запуск отклоняется (ConflictError 409): индексация и так одна
// на весь сервис, а Ollama на VPS обслуживает запросы по одному.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ConflictError } from "../domain/errors.js";
import type { Logger } from "../logger.js";
import { silentLogger } from "../logger.js";
import type { KbRepo } from "../store/kbRepo.js";
import { chunkMarkdown, type KbChunk } from "./chunker.js";
import type { Embedder } from "./embedder.js";

const EMBED_BATCH = 16;

export class KbIndexer {
  private running = false;

  constructor(
    private readonly repo: KbRepo,
    private readonly kbDir: string,
    private readonly now: () => Date = () => new Date(),
    private readonly logger: Logger = silentLogger,
  ) {}

  isRunning(): boolean {
    return this.running;
  }

  /** Список .md файлов KB (плоский каталог; имена — источники цитат). */
  listFiles(): string[] {
    try {
      return readdirSync(this.kbDir)
        .filter((f) => f.endsWith(".md"))
        .sort();
    } catch {
      return [];
    }
  }

  /**
   * Полная переиндексация. Бросает ConflictError при уже идущей индексации;
   * ошибки эмбеддера фиксируются в kb_meta (status=error), НЕ бросаются наружу
   * повторно — вызывающий фоновый таск их уже залогировал.
   */
  async reindex(embedder: Embedder): Promise<{ chunkCount: number }> {
    if (this.running) throw new ConflictError("Переиндексация уже идёт.");
    this.running = true;
    this.repo.setMeta({ status: "indexing", lastError: "" });
    try {
      const chunks: KbChunk[] = [];
      for (const file of this.listFiles()) {
        const text = readFileSync(join(this.kbDir, file), "utf8");
        chunks.push(...chunkMarkdown(text, file));
      }

      const vectors: Float32Array[] = [];
      for (let i = 0; i < chunks.length; i += EMBED_BATCH) {
        const batch = chunks.slice(i, i + EMBED_BATCH);
        vectors.push(...(await embedder.embed(batch.map((c) => c.text))));
      }

      const dim = vectors[0]?.length ?? 0;
      const tag = `${embedder.model}|${dim}`;
      this.repo.replaceAll(
        chunks.map((c, i) => ({
          path: c.filePath,
          section: c.headingPath,
          text: c.text,
          vec: vectors[i]!,
        })),
        tag,
        this.now().toISOString(),
      );
      this.logger.info({ chunks: chunks.length, tag }, "KB переиндексирована");
      return { chunkCount: chunks.length };
    } catch (e) {
      const msg = (e as Error).message;
      this.repo.setMeta({ status: "error", lastError: msg });
      this.logger.error({ err: msg }, "ошибка переиндексации KB");
      throw e;
    } finally {
      this.running = false;
    }
  }
}
