// OllamaProvider.swift — ChatProvider + EmbeddingProvider поверх локального
// Ollama. Каждый вызов: ленивый старт сервера (OllamaManager.ensureRunning) →
// запрос → markUsed (сдвиг idle-окна). Регистрируется в ProviderRegistry с
// isLocal=true (ключ не нужен); доступность = бинарь установлен ЛИБО сервер
// уже отвечает (чужой) — роутер сам уйдёт на облако, если Ollama нет.

import Foundation

final class OllamaProvider: ChatProvider, EmbeddingProvider {
    static let id: ProviderID = "ollama"

    // internal: tools-расширение (задача 15) живёт в MCP/ProviderToolSupport.swift.
    let manager: OllamaManager
    let client: OllamaClient
    /// Размерность эмбеддингов дефолтной модели (nomic-embed-text — 768).
    let dimension: Int

    /// Модель эмбеддингов фиксирована отдельно от чата: embed(_:) в протоколе
    /// не принимает модель (роутер выбирает провайдера, не модель эмбеддинга).
    let embeddingModel: String

    init(manager: OllamaManager,
         dimension: Int = 768,
         embeddingModel: String = "nomic-embed-text") {
        self.manager = manager
        self.client = OllamaClient(baseURL: manager.baseURL)
        self.dimension = dimension
        self.embeddingModel = embeddingModel
    }

    // MARK: - ChatProvider

    func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult {
        try await manager.ensureRunning()
        let result = try await client.chat(messages: messages, settings: settings)
        await manager.markUsed()
        return result
    }

    func stream(_ messages: [ChatMessageDTO],
                settings: ChatSettings) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await manager.ensureRunning()
                    for try await event in client.chatStream(messages: messages,
                                                             settings: settings) {
                        continuation.yield(event)
                    }
                    await manager.markUsed()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - EmbeddingProvider

    func embed(_ texts: [String], model: String?) async throws -> [[Float]] {
        try await manager.ensureRunning()
        let vectors = try await client.embed(texts: texts, model: model ?? embeddingModel)
        await manager.markUsed()
        return vectors
    }
}

/// Регистрация локальных провайдеров (вызов из ContentView.init после облачных).
@MainActor
enum LocalProviders {
    static func register(in registry: ProviderRegistry, ollamaManager: OllamaManager) {
        let provider = OllamaProvider(manager: ollamaManager)
        registry.register(
            ProviderDescriptor(id: OllamaProvider.id,
                               displayName: "Ollama (локально)",
                               capabilities: [.chat, .embedding],
                               isLocal: true,
                               defaultModel: "qwen3:8b",
                               defaultEmbeddingModel: "nomic-embed-text"),
            chat: provider,
            embedding: provider,
            // Доступен, если установлен бинарь ЛИБО уже работает (в т.ч. чужой).
            isAvailable: { [weak ollamaManager] in
                guard let manager = ollamaManager else { return false }
                return manager.isInstalled || manager.status != .stopped
            })
    }

    /// Whisper (задача 10): доступен, только когда скачана хоть одна модель —
    /// иначе роутер мог бы молча запустить закачку гигабайтов с Hugging Face.
    static func registerWhisper(in registry: ProviderRegistry, provider: WhisperKitProvider) {
        registry.register(
            ProviderDescriptor(id: WhisperKitProvider.id,
                               displayName: "Whisper (локально)",
                               capabilities: [.transcription],
                               isLocal: true,
                               defaultModel: WhisperVariant.recommendedName),
            transcription: provider,
            isAvailable: { [weak provider] in
                provider?.hasInstalledModel(base: WhisperModelStorage.defaultDownloadBase) ?? false
            })
    }
}
