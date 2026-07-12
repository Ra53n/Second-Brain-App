// RagVector.swift — векторная математика RAG (порт Vector из MA).
//
// Поиск top-K — brute-force косинус по всем векторам (семантика FAISS
// IndexFlatL2): для личного vault (тысячи чанков) это миллисекунды, внешние
// зависимости (sqlite-vec и т.п.) не нужны — решение зафиксировано в
// ARCHITECTURE.md.

import Foundation

enum Vector {
    /// Скалярное произведение (длины должны совпадать; иначе по минимальной).
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var s: Float = 0
        var i = 0
        while i < n { s += a[i] * b[i]; i += 1 }
        return s
    }

    /// Евклидова норма.
    static func norm(_ a: [Float]) -> Float { sqrt(dot(a, a)) }

    /// L2-нормализация (нулевой вектор остаётся нулевым).
    static func normalize(_ a: [Float]) -> [Float] {
        let n = norm(a)
        guard n > 0 else { return a }
        return a.map { $0 / n }
    }

    /// Косинусная близость в [-1, 1] (1 — сонаправлены, 0 — ортогональны).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let na = norm(a), nb = norm(b)
        guard na > 0, nb > 0 else { return 0 }
        return dot(a, b) / (na * nb)
    }

    /// top-K индексов матрицы, ближайших к запросу по косинусу (по убыванию).
    static func topK(query: [Float], matrix: [[Float]], k: Int) -> [(index: Int, score: Float)] {
        guard k > 0, !matrix.isEmpty else { return [] }
        let scored = matrix.enumerated().map { (index: $0.offset, score: cosine(query, $0.element)) }
        return Array(scored.sorted { $0.score > $1.score }.prefix(k))
    }
}
