// MockProviders.swift — детерминированные реализации протоколов LLM для тестов.
//
// Живут в основном таргете (не в Tests/), как HashingEmbedder в Manager
// Assistant: их используют не только тесты этой задачи, но и тесты будущих
// задач (11 — транскрипция, 12 — чат, 13 — RAG-индексация) через
// `@testable import SecondBrain`, без сети и без флаки-таймингов.

import Foundation

/// Мок ChatProvider с канонированными ответами по кругу. Позволяет:
///  - задать очередь ответов (для многошаговых сценариев — задача 11/12);
///  - смоделировать ошибку провайдера (`errorToThrow`);
///  - смоделировать задержку сети (`delay`), по умолчанию 0 — тесты не ждут.
final class MockChatProvider: ChatProvider {
    private var responses: [String]
    private var index = 0
    var errorToThrow: Error?
    var delay: TimeInterval = 0
    /// Все запросы, дошедшие до send()/stream() — для проверки, что послали то, что ожидалось.
    private(set) var receivedMessages: [[ChatMessageDTO]] = []

    init(responses: [String] = ["Тестовый ответ"]) {
        self.responses = responses
    }

    private func nextResponse() -> String {
        guard !responses.isEmpty else { return "" }
        defer { index = (index + 1) % responses.count }
        return responses[index]
    }

    func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
        receivedMessages.append(messages)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let errorToThrow { throw errorToThrow }
        let text = nextResponse()
        return ChatResult(
            text: text,
            usage: ChatUsage(promptTokens: 10, completionTokens: text.count, totalTokens: 10 + text.count)
        )
    }

    func stream(_ messages: [ChatMessageDTO], settings: ChatSettings) -> AsyncThrowingStream<String, Error> {
        receivedMessages.append(messages)
        let text = nextResponse()
        let error = errorToThrow
        let delaySeconds = delay
        return AsyncThrowingStream { continuation in
            Task {
                if delaySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                for word in text.split(separator: " ") {
                    continuation.yield(String(word) + " ")
                }
                continuation.finish()
            }
        }
    }
}

/// Мок TranscriptionProvider: фиксированный транскрипт, без сети.
final class MockTranscriptionProvider: TranscriptionProvider {
    var result: Transcript
    var errorToThrow: Error?

    init(result: Transcript = Transcript(fullText: "тестовый транскрипт", segments: [], language: "ru")) {
        self.result = result
    }

    func transcribe(audioURL: URL, language: String?, hints: String?) async throws -> Transcript {
        if let errorToThrow { throw errorToThrow }
        return result
    }
}

/// Детерминированный bag-of-words эмбеддер: без сети и зависимостей,
/// воспроизводим — используется в юнит-тестах (12, 13, 14) и как возможный
/// офлайн-фолбэк. Порт HashingEmbedder из Manager Assistant (RagEmbedding.swift);
/// полноценная векторная математика (cosine/topK) появится вместе с
/// RAG-индексом (задача 13) — здесь только то, что нужно для embed().
struct HashingEmbedder: EmbeddingProvider {
    let dimension: Int

    init(dimension: Int = 256) {
        self.dimension = max(8, dimension)
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map(vector(for:))
    }

    func vector(for text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for token in Self.tokens(text) {
            let hash = Self.fnv1a(token)
            let bucket = Int(hash % UInt64(dimension))
            let sign: Float = (hash & 1) == 0 ? 1 : -1 // знак из младшего бита — снижает смещение
            v[bucket] += sign
        }
        return Self.normalized(v)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// FNV-1a 64-bit — быстрый детерминированный хеш строки (не Hasher, у него сид рандомизирован).
    private static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}
