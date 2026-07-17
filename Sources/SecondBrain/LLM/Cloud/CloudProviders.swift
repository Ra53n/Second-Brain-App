// CloudProviders.swift — регистрация облачных провайдеров в ProviderRegistry.
//
// Задача 07 построила механизм (протоколы, реестр, роутинг), эта задача (08) —
// конкретные HTTP-клиенты; регистрация — тонкий связующий слой между ними,
// вызывается один раз при старте приложения (ContentView.init).
//
// defaultModel у каждого дескриптора — модель, которую роутер подставит по
// умолчанию, если пользователь явно не назначил функцию (задача 07,
// FunctionRouter.defaultAssignment); выбраны недорогие/быстрые модели.

import Foundation

@MainActor
enum CloudProviders {
    /// OpenAI-совместимые провайдеры без своих клиентов (задача 26):
    /// id — ключ в KeyStore и env-fallback (SECONDBRAIN_<ID>_KEY).
    static let openRouterID: ProviderID = "openrouter"
    static let deepSeekID: ProviderID = "deepseek"

    static func registerAll(in registry: ProviderRegistry) {
        let openAI = OpenAIProvider()
        registry.register(
            ProviderDescriptor(
                id: OpenAIProvider.id,
                displayName: "OpenAI",
                capabilities: [.chat, .transcription, .embedding],
                isLocal: false,
                defaultModel: "gpt-4o-mini",
                defaultEmbeddingModel: OpenAIProvider.defaultEmbeddingModel
            ),
            chat: openAI,
            transcription: openAI,
            embedding: openAI
        )

        let gemini = GeminiProvider()
        registry.register(
            ProviderDescriptor(
                id: GeminiProvider.id,
                displayName: "Google Gemini",
                capabilities: [.chat, .transcription, .embedding],
                isLocal: false,
                defaultModel: "gemini-2.0-flash",
                defaultEmbeddingModel: "text-embedding-004"
            ),
            chat: gemini,
            transcription: gemini,
            embedding: gemini
        )

        registry.register(
            ProviderDescriptor(
                id: DeepgramProvider.id,
                displayName: "Deepgram",
                capabilities: [.transcription],
                isLocal: false,
                defaultModel: "nova-2"
            ),
            transcription: DeepgramProvider()
        )

        registry.register(
            ProviderDescriptor(
                id: AssemblyAIProvider.id,
                displayName: "AssemblyAI",
                capabilities: [.transcription],
                isLocal: false,
                defaultModel: "best"
            ),
            transcription: AssemblyAIProvider()
        )

        // OpenRouter и DeepSeek (задача 26): OpenAI-совместимые чат-API —
        // тот же клиент с другим baseURL и ключом; function calling работает
        // через существующее расширение ToolCapableChatProvider.
        registry.register(
            ProviderDescriptor(
                id: openRouterID,
                displayName: "OpenRouter",
                capabilities: [.chat],
                isLocal: false,
                defaultModel: "deepseek/deepseek-chat"
            ),
            chat: OpenAIProvider(baseURL: URL(string: "https://openrouter.ai/api/v1")!,
                                 keyID: openRouterID)
        )

        registry.register(
            ProviderDescriptor(
                id: deepSeekID,
                displayName: "DeepSeek",
                capabilities: [.chat],
                isLocal: false,
                defaultModel: "deepseek-chat"
            ),
            chat: OpenAIProvider(baseURL: URL(string: "https://api.deepseek.com/v1")!,
                                 keyID: deepSeekID)
        )
    }
}
