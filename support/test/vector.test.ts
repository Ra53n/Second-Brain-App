// Тесты векторной математики (cosine/topK) и сериализации BLOB.

import { describe, expect, it } from "vitest";
import { blobToVec, cosine, topK, vecToBlob } from "../src/rag/vector.js";

const v = (...xs: number[]) => Float32Array.from(xs);

describe("cosine", () => {
  it("сонаправленные → 1, ортогональные → 0", () => {
    expect(cosine(v(1, 0), v(2, 0))).toBeCloseTo(1);
    expect(cosine(v(1, 0), v(0, 3))).toBeCloseTo(0);
    expect(cosine(v(1, 1), v(-1, -1))).toBeCloseTo(-1);
  });

  it("нулевой вектор → 0 (не NaN)", () => {
    expect(cosine(v(0, 0), v(1, 2))).toBe(0);
  });
});

describe("topK", () => {
  it("возвращает индексы по убыванию близости", () => {
    const matrix = [v(0, 1), v(1, 0), v(0.9, 0.1)];
    const hits = topK(v(1, 0), matrix, 2);
    expect(hits.map((h) => h.index)).toEqual([1, 2]);
    expect(hits[0]!.score).toBeGreaterThan(hits[1]!.score);
  });

  it("k больше матрицы и пустая матрица", () => {
    expect(topK(v(1), [], 3)).toEqual([]);
    expect(topK(v(1), [v(1)], 5)).toHaveLength(1);
  });
});

describe("vecToBlob/blobToVec", () => {
  it("round-trip сохраняет значения (Float32-LE)", () => {
    const orig = v(0.5, -1.25, 3.75, 0);
    const back = blobToVec(vecToBlob(orig));
    expect([...back]).toEqual([...orig]);
  });
});
