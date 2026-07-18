// embedder.ts — эмбеддеры RAG (порт RagEmbedding.swift MA, две реализации).
//
//   • OllamaEmbedder  — локальная Ollama /api/embed (bge-m3: мультиязычный,
//                       хорошо держит русский). Размерность неизвестна заранее —
//                       берётся из первого ответа.
//   • HashingEmbedder — детерминированный bag-of-words FNV-1a хеш со знаком.
//                       Без сети, воспроизводим → юнит-тесты и аварийный фолбэк.

import type { OllamaClient } from "../llm/ollamaClient.js";

/** Превращает пакет текстов в пакет векторов (порядок сохраняется). */
export interface Embedder {
  /** Идентификатор модели — пишется в kb_meta.embeddingTag вместе с dim. */
  readonly model: string;
  embed(texts: string[]): Promise<Float32Array[]>;
}

export class OllamaEmbedder implements Embedder {
  constructor(
    private readonly ollama: OllamaClient,
    public readonly model: string,
  ) {}

  async embed(texts: string[]): Promise<Float32Array[]> {
    if (texts.length === 0) return [];
    const vectors = await this.ollama.embed(this.model, texts);
    return vectors.map((v) => Float32Array.from(v));
  }
}

// ── HashingEmbedder ──────────────────────────────────────────────────────────

const FNV_OFFSET = 0x811c9dc5;
const FNV_PRIME = 0x01000193;

/** 32-битный FNV-1a хеш строки. */
export function fnv1a(s: string): number {
  let h = FNV_OFFSET;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, FNV_PRIME) >>> 0;
  }
  return h >>> 0;
}

/** Токенизация bag-of-words: слова из букв/цифр в нижнем регистре (юникод). */
export function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((t) => t.length > 0);
}

/**
 * Feature hashing: токен → бакет (hash % dim) со знаком ±1 (бит хеша), частоты
 * суммируются, вектор L2-нормализуется. Детерминирован и не требует модели.
 */
export class HashingEmbedder implements Embedder {
  readonly model: string;

  constructor(private readonly dim = 256) {
    this.model = `hashing-${dim}`;
  }

  async embed(texts: string[]): Promise<Float32Array[]> {
    return texts.map((t) => this.embedOne(t));
  }

  private embedOne(text: string): Float32Array {
    const v = new Float32Array(this.dim);
    for (const token of tokenize(text)) {
      const h = fnv1a(token);
      const bucket = h % this.dim;
      const sign = (h & 0x80000000) !== 0 ? -1 : 1;
      v[bucket]! += sign;
    }
    // L2-нормализация (нулевой вектор остаётся нулевым).
    let n = 0;
    for (let i = 0; i < v.length; i++) n += v[i]! * v[i]!;
    n = Math.sqrt(n);
    if (n > 0) for (let i = 0; i < v.length; i++) v[i]! /= n;
    return v;
  }
}
