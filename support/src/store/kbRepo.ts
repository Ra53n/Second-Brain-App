// kbRepo.ts — хранение индекса базы знаний: чанки + векторы (Float32-LE BLOB)
// в SQLite, метаданные в kb_meta. Индекс полностью пересоздаваем — источник
// правды это .md файлы в KB_DIR (паттерн rag.sqlite из DATA-MODEL.md).

import type { DB } from "./db.js";
import { blobToVec, vecToBlob } from "../rag/vector.js";

export interface StoredKbChunk {
  id: number;
  path: string;
  section: string;
  ordinal: number;
  text: string;
}

export type KbStatus = "empty" | "indexing" | "ready" | "error";

export interface KbMeta {
  status: KbStatus;
  embeddingTag: string; // "<model>|<dim>", напр. "bge-m3|1024"
  chunkCount: number;
  updatedAt: string;
  lastError: string;
}

export class KbRepo {
  constructor(private readonly db: DB) {}

  getMeta(): KbMeta {
    const rows = this.db.prepare(`SELECT key, value FROM kb_meta`).all() as Array<{
      key: string;
      value: string;
    }>;
    const m = new Map(rows.map((r) => [r.key, r.value]));
    return {
      status: (m.get("status") as KbStatus) ?? "empty",
      embeddingTag: m.get("embeddingTag") ?? "",
      chunkCount: Number.parseInt(m.get("chunkCount") ?? "0", 10) || 0,
      updatedAt: m.get("updatedAt") ?? "",
      lastError: m.get("lastError") ?? "",
    };
  }

  setMeta(patch: Partial<KbMeta>): void {
    const stmt = this.db.prepare(
      `INSERT INTO kb_meta (key, value) VALUES (?, ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    );
    const tx = this.db.transaction(() => {
      for (const [key, value] of Object.entries(patch)) {
        stmt.run(key, String(value));
      }
    });
    tx();
  }

  /** Атомарно заменяет весь индекс (чанки + векторы + мета ready). */
  replaceAll(
    chunks: Array<{ path: string; section: string; text: string; vec: Float32Array }>,
    embeddingTag: string,
    updatedAt: string,
  ): void {
    const insert = this.db.prepare(
      `INSERT INTO kb_chunks (path, section, ordinal, text, vec, dim)
       VALUES (@path, @section, @ordinal, @text, @vec, @dim)`,
    );
    const tx = this.db.transaction(() => {
      this.db.prepare(`DELETE FROM kb_chunks`).run();
      chunks.forEach((c, ordinal) => {
        insert.run({
          path: c.path,
          section: c.section,
          ordinal,
          text: c.text,
          vec: vecToBlob(c.vec),
          dim: c.vec.length,
        });
      });
      const meta = this.db.prepare(
        `INSERT INTO kb_meta (key, value) VALUES (?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
      );
      meta.run("status", "ready");
      meta.run("embeddingTag", embeddingTag);
      meta.run("chunkCount", String(chunks.length));
      meta.run("updatedAt", updatedAt);
      meta.run("lastError", "");
    });
    tx();
  }

  /** Все чанки с векторами (для brute-force поиска; корпус маленький). */
  loadAll(): { chunks: StoredKbChunk[]; vectors: Float32Array[] } {
    const rows = this.db
      .prepare(`SELECT id, path, section, ordinal, text, vec FROM kb_chunks ORDER BY ordinal ASC`)
      .all() as Array<{
      id: number;
      path: string;
      section: string;
      ordinal: number;
      text: string;
      vec: Buffer;
    }>;
    return {
      chunks: rows.map((r) => ({
        id: r.id,
        path: r.path,
        section: r.section,
        ordinal: r.ordinal,
        text: r.text,
      })),
      vectors: rows.map((r) => blobToVec(r.vec)),
    };
  }
}
