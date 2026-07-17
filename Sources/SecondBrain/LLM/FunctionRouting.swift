// FunctionRouting.swift — роутинг «функция приложения → провайдер+модель».
//
// Здесь живут:
//  - AppFunction            — какие функции вообще нуждаются в модели;
//  - FunctionAssignment     — назначение: конкретный провайдер + модель;
//  - FunctionRoutingConfig  — персистентный словарь функция→назначение;
//  - FunctionRoutingStore   — сохранение на диск (паттерн ChatStore MA);
//  - FunctionRouter         — совмещает конфиг с ProviderRegistry: отдаёт
//                             валидный провайдер+модель на функцию, с дефолтом
//                             «первый доступный провайдер нужного протокола»,
//                             если явного назначения нет или оно протухло
//                             (провайдер удалён/недоступен).
//
// FunctionAssignment.model осмысленно используется по-разному в зависимости
// от способности функции: у чата модель передаётся в ChatSettings.model
// (провайдер обслуживает много моделей); у транскрипции/эмбеддингов модель
// обычно «зашита» в конкретный экземпляр провайдера при регистрации (09/10) —
// там это поле скорее для отображения в UI настроек (задача 17), чем для
// передачи в вызов.

import Foundation
import Combine

/// Функция приложения, которой нужна модель. UI настроек (задача 17)
/// перечисляет их через allCases.
enum AppFunction: String, Codable, CaseIterable {
    case transcription
    case meetingSummary
    case chat
    case embedding
    case noteFiling
    /// Переранжирование и переписывание запроса RAG (задача 28): раньше
    /// молча использовалась модель функции «чат» — теперь настраивается явно.
    case ragRerank

    /// Протокол провайдера, обязательный для этой функции — им валидируется
    /// назначение (нельзя поставить embedding-провайдер на транскрипцию).
    var requiredCapability: ProviderCapability {
        switch self {
        case .transcription: return .transcription
        case .meetingSummary, .chat, .noteFiling, .ragRerank: return .chat
        case .embedding: return .embedding
        }
    }

    var displayName: String {
        switch self {
        case .transcription: return "Транскрипция"
        case .meetingSummary: return "Саммари встречи"
        case .chat: return "Чат"
        case .embedding: return "Эмбеддинги"
        case .noteFiling: return "Раскладка заметок"
        case .ragRerank: return "RAG: переранжирование и переписывание запроса"
        }
    }
}

/// Назначение функции: конкретный провайдер + модель.
struct FunctionAssignment: Equatable, Codable {
    var providerID: ProviderID
    var model: String
}

/// Персистентный конфиг роутинга. Ключ — AppFunction.rawValue (не сам enum):
/// словарь с произвольным Codable-ключом сериализовался бы неоднозначно между
/// версиями Swift, а строковый ключ — предсказуемый JSON-объект и просто
/// мигрируется. Побочный эффект на пользу миграции: назначение для функции,
/// которой в текущей версии уже нет, не теряется при пересохранении — просто
/// висит неиспользуемым, пока функция не вернётся.
struct FunctionRoutingConfig: Codable, Equatable {
    private(set) var raw: [String: FunctionAssignment]

    init() {
        raw = [:]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Битый/пустой конфиг — не повод падать, просто нет назначений.
        raw = (try? container.decode([String: FunctionAssignment].self)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    subscript(function: AppFunction) -> FunctionAssignment? {
        get { raw[function.rawValue] }
        set { raw[function.rawValue] = newValue }
    }
}

/// Персистентность конфига роутинга: JSON в Application Support, атомарная
/// запись, повреждённый файл откладывается в сторону (паттерн ChatStore MA).
/// Изменения роутинга — редкое действие пользователя в настройках, не поток
/// ввода, поэтому пишем сразу, без debounce.
enum FunctionRoutingStore {
    static var fileURL: URL {
        Config.appSupportDirectory.appendingPathComponent("routing.json")
    }

    static func load() -> FunctionRoutingConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return FunctionRoutingConfig() }
        do {
            return try JSONDecoder().decode(FunctionRoutingConfig.self, from: data)
        } catch {
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return FunctionRoutingConfig()
        }
    }

    static func save(_ config: FunctionRoutingConfig) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Провайдер+модель, отданные роутером на конкретный вызов. providerID и
/// displayName — для метрик сообщения и «Авто → …» (задача 29).
struct ResolvedChatProvider {
    let provider: ChatProvider
    let model: String
    let providerID: ProviderID
    let displayName: String
}
struct ResolvedTranscriptionProvider { let provider: TranscriptionProvider; let model: String }
struct ResolvedEmbeddingProvider { let provider: EmbeddingProvider; let model: String }

/// Роутер: конфиг назначений + реестр провайдеров → готовый к вызову провайдер.
/// Явное назначение пользователя используется, только если провайдер всё ещё
/// существует, поддерживает нужный протокол и доступен прямо сейчас; иначе —
/// прозрачный дефолт (первый доступный провайдер нужной способности), чтобы
/// приложение не переставало работать после удаления/отзыва ключа провайдера.
@MainActor
final class FunctionRouter: ObservableObject {
    @Published private(set) var config: FunctionRoutingConfig
    let registry: ProviderRegistry

    init(registry: ProviderRegistry, config: FunctionRoutingConfig = FunctionRoutingStore.load()) {
        self.registry = registry
        self.config = config
    }

    /// Явное назначение пользователя для функции, чтобы показать в UI настроек
    /// (задача 17) — в отличие от resolve* не подставляет дефолт.
    func assignment(for function: AppFunction) -> FunctionAssignment? {
        config[function]
    }

    /// Назначает функцию на провайдер+модель и сохраняет немедленно.
    func assign(_ assignment: FunctionAssignment, to function: AppFunction) {
        config[function] = assignment
        FunctionRoutingStore.save(config)
    }

    /// Снимает назначение — функция вернётся к автодефолту.
    func clearAssignment(for function: AppFunction) {
        config[function] = nil
        FunctionRoutingStore.save(config)
    }

    func resolveChatProvider(for function: AppFunction) -> ResolvedChatProvider? {
        guard function.requiredCapability == .chat else { return nil }
        if let assignment = validAssignment(for: function),
           let provider = registry.chatProvider(for: assignment.providerID) {
            return ResolvedChatProvider(
                provider: provider, model: assignment.model,
                providerID: assignment.providerID,
                displayName: registry.descriptor(for: assignment.providerID)?.displayName
                    ?? assignment.providerID.rawValue)
        }
        guard let (id, model) = defaultAssignment(for: .chat),
              let provider = registry.chatProvider(for: id) else { return nil }
        return ResolvedChatProvider(
            provider: provider, model: model, providerID: id,
            displayName: registry.descriptor(for: id)?.displayName ?? id.rawValue)
    }

    func resolveTranscriptionProvider(for function: AppFunction) -> ResolvedTranscriptionProvider? {
        guard function.requiredCapability == .transcription else { return nil }
        if let assignment = validAssignment(for: function),
           let provider = registry.transcriptionProvider(for: assignment.providerID) {
            return ResolvedTranscriptionProvider(provider: provider, model: assignment.model)
        }
        guard let (id, model) = defaultAssignment(for: .transcription),
              let provider = registry.transcriptionProvider(for: id) else { return nil }
        return ResolvedTranscriptionProvider(provider: provider, model: model)
    }

    func resolveEmbeddingProvider(for function: AppFunction) -> ResolvedEmbeddingProvider? {
        guard function.requiredCapability == .embedding else { return nil }
        if let assignment = validAssignment(for: function),
           let provider = registry.embeddingProvider(for: assignment.providerID) {
            return ResolvedEmbeddingProvider(provider: provider, model: assignment.model)
        }
        guard let (id, model) = defaultAssignment(for: .embedding),
              let provider = registry.embeddingProvider(for: id) else { return nil }
        return ResolvedEmbeddingProvider(provider: provider, model: model)
    }

    // MARK: - Внутреннее

    /// Явное назначение годится, только если провайдер существует, всё ещё
    /// поддерживает нужную способность и доступен (ключ есть/рантайм жив).
    private func validAssignment(for function: AppFunction) -> FunctionAssignment? {
        guard let assignment = config[function],
              let descriptor = registry.descriptor(for: assignment.providerID),
              descriptor.capabilities.contains(function.requiredCapability),
              registry.isAvailable(assignment.providerID) else {
            return nil
        }
        return assignment
    }

    /// Первый доступный провайдер способности с известной моделью по умолчанию
    /// (провайдеры без defaultModel не участвуют в автодефолте — их нечем вызвать).
    /// Модель берётся per-capability (задача 28): у Ollama эмбеддинги — не qwen3.
    private func defaultAssignment(for capability: ProviderCapability) -> (ProviderID, String)? {
        for descriptor in registry.descriptors(supporting: capability) where registry.isAvailable(descriptor.id) {
            if let model = descriptor.defaultModel(for: capability) {
                return (descriptor.id, model)
            }
        }
        return nil
    }
}
