// ProviderProtocols.swift — протоколы доступа к моделям + общие DTO/ошибки.
//
// Три способности, которые умеет провайдер (см. ProviderCapability):
//   ChatProvider          — диалог, с обычным и потоковым (стриминг) ответом;
//   TranscriptionProvider — аудио → текст с таймкодами, если провайдер их отдаёт;
//   EmbeddingProvider     — текст → вектор (для RAG, задача 13).
//
// Конкретных реализаций здесь нет (облачные — задача 08, Ollama/WhisperKit —
// 09/10) — только контракт + мок-провайдеры для тестов (MockProviders.swift).
// Модель, к которой обращается вызов, для чата передаётся в ChatSettings.model
// (роутер задачи 07 подставляет её из FunctionAssignment); у транскрипции и
// эмбеддингов модель обычно «зашита» в конкретный экземпляр провайдера при
// его регистрации (см. FunctionAssignment.model в FunctionRouting.swift).

import Foundation

// MARK: - Чат

/// Сообщение диалога в формате, который отправляется провайдеру. Доменная
/// модель чата (с id, метриками и т.п.) — в Chat/ChatModels.swift (задача 12);
/// это DTO — только то, что действительно нужно для запроса.
struct ChatMessageDTO: Equatable, Codable {
    enum Role: String, Codable {
        case system, user, assistant
    }
    let role: Role
    let content: String
}

/// Параметры запроса чата: модель + семплирование. Единственный параметр
/// send()/stream() — вызывающая сторона (ChatViewModel, задача 12) собирает
/// его из настроек чата + модели, отданной FunctionRouter.
struct ChatSettings: Equatable, Codable {
    var model: String
    var temperature: Double = 1.0
    var topP: Double = 1.0
    var maxTokens: Int = 4096
    /// Стоп-последовательности; пустой массив — не отправлять провайдеру.
    var stop: [String] = []
}

/// Расход токенов запроса — для метрик стоимости/скорости (порт MessageMetrics MA).
struct ChatUsage: Equatable, Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

/// Результат нестримингового запроса.
struct ChatResult: Equatable {
    let text: String
    /// nil — провайдер не вернул usage (бывает у некоторых локальных серверов).
    let usage: ChatUsage?
}

/// Провайдер чата: обычный и потоковый ответ. Оба метода получают ПОЛНУЮ
/// историю сообщений — стратегии обрезки контекста (если появятся) живут
/// выше, в вызывающем коде (Chat, задача 12), а не в провайдере.
protocol ChatProvider {
    func send(_ messages: [ChatMessageDTO], settings: ChatSettings) async throws -> ChatResult

    /// Токены ответа по мере готовности. Ошибка сети/API — через `finish(throwing:)`
    /// потока, не через throws самого метода (метод синхронно возвращает поток).
    func stream(_ messages: [ChatMessageDTO], settings: ChatSettings) -> AsyncThrowingStream<String, Error>
}

// MARK: - Транскрипция

/// Один сегмент транскрипта. start/end — nil, если провайдер не отдаёт таймкоды.
struct TranscriptSegment: Equatable, Codable {
    let text: String
    let start: TimeInterval?
    let end: TimeInterval?
}

/// Результат транскрипции: полный текст (для summary) + сегменты (для показа
/// с таймкодами в заметке встречи, задача 11).
struct Transcript: Equatable, Codable {
    let fullText: String
    let segments: [TranscriptSegment]
    /// Язык, определённый провайдером (BCP-47/ISO код), если отдаёт.
    let language: String?
}

/// Провайдер транскрипции аудио в текст.
protocol TranscriptionProvider {
    /// - Parameters:
    ///   - language: подсказка языка (ISO 639-1), если известен заранее; nil — автоопределение.
    ///   - hints: словарь/контекст (имена, термины) — не все провайдеры используют.
    func transcribe(audioURL: URL, language: String?, hints: String?) async throws -> Transcript
}

// MARK: - Эмбеддинги

/// Провайдер эмбеддингов: текст → вектор. Размерность фиксирована для
/// конкретного экземпляра (проверяется при инвалидации RAG-индекса, задача 13).
protocol EmbeddingProvider {
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension EmbeddingProvider {
    /// Удобный вызов для одного текста.
    func embedOne(_ text: String) async throws -> [Float] {
        let vectors = try await embed([text])
        guard let first = vectors.first else { throw LLMError.emptyResponse }
        return first
    }
}

// MARK: - Ошибки

/// Ошибки LLM-слоя с текстами, готовыми к показу пользователю.
enum LLMError: LocalizedError, Equatable {
    case missingAPIKey(ProviderID)
    case providerUnavailable(ProviderID)
    case badStatus(code: Int, message: String)
    case emptyResponse
    case unsupportedCapability(ProviderID, ProviderCapability)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let id):
            return "Не задан API-ключ для «\(id.rawValue)». Добавьте его в настройках или переменной окружения \(KeyStore.envVar(for: id))."
        case .providerUnavailable(let id):
            return "Провайдер «\(id.rawValue)» сейчас недоступен (рантайм не запущен или ключ не работает)."
        case .badStatus(let code, let message):
            return "Ошибка API (\(code)): \(message)"
        case .emptyResponse:
            return "Пустой ответ от модели."
        case .unsupportedCapability(let id, let capability):
            return "Провайдер «\(id.rawValue)» не поддерживает функцию «\(capability.rawValue)»."
        }
    }
}
