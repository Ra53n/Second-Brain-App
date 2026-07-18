// vector.ts — векторная математика RAG (порт RagVector.swift / Vector из MA).
//
// Поиск top-K — brute-force косинус по всем векторам: для базы знаний саппорта
// (десятки–сотни чанков) это микросекунды, внешние векторные БД не нужны.

export function dot(a: Float32Array, b: Float32Array): number {
  const n = Math.min(a.length, b.length);
  let s = 0;
  for (let i = 0; i < n; i++) s += a[i]! * b[i]!;
  return s;
}

export function norm(a: Float32Array): number {
  return Math.sqrt(dot(a, a));
}

/** Косинусная близость в [-1, 1] (0 — при нулевом векторе). */
export function cosine(a: Float32Array, b: Float32Array): number {
  const na = norm(a);
  const nb = norm(b);
  if (na === 0 || nb === 0) return 0;
  return dot(a, b) / (na * nb);
}

/** top-K индексов матрицы, ближайших к запросу по косинусу (по убыванию score). */
export function topK(
  query: Float32Array,
  matrix: Float32Array[],
  k: number,
): Array<{ index: number; score: number }> {
  if (k <= 0 || matrix.length === 0) return [];
  const scored = matrix.map((v, index) => ({ index, score: cosine(query, v) }));
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, k);
}

/** Float32Array → BLOB (little-endian) для SQLite. */
export function vecToBlob(v: Float32Array): Buffer {
  return Buffer.from(v.buffer, v.byteOffset, v.byteLength);
}

/** BLOB из SQLite → Float32Array (копия, чтобы не зависеть от пула буферов). */
export function blobToVec(blob: Buffer): Float32Array {
  const copy = Buffer.from(blob);
  return new Float32Array(copy.buffer, copy.byteOffset, copy.byteLength / 4);
}
