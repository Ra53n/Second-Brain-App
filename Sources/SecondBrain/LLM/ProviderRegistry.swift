// ProviderRegistry.swift — реестр известных провайдеров и их живых реализаций.
//
// Регистрация — дело конкретных провайдеров (облачные — задача 08, локальные —
// 09/10): при старте приложения (или лениво) они вызывают `register(...)` с
// дескриптором + своими протокольными реализациями. Здесь эта конкретика не
// живёт — только механизм: что известно, что доступно прямо сейчас, как
// достать реализацию по id.

import Foundation

/// Стабильный идентификатор провайдера. Строка, а не enum-кейсы: новые
/// провайдеры (08/09/10) добавляются регистрацией, без правки этого файла.
/// Используется как ключ персистентности в FunctionRoutingConfig — стабильность
/// важнее удобства (не переименовывать задним числом).
struct ProviderID: RawRepresentable, Hashable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }
    var description: String { rawValue }
}

/// Какой протокол умеет провайдер. Один провайдер может поддерживать
/// несколько сразу (например, OpenAI — chat и embedding).
enum ProviderCapability: String, Codable, CaseIterable {
    case chat
    case transcription
    case embedding
}

/// Метаданные провайдера в реестре (без самой реализации — она регистрируется
/// отдельно, см. ProviderRegistry.register).
struct ProviderDescriptor: Identifiable, Equatable {
    let id: ProviderID
    let displayName: String
    let capabilities: Set<ProviderCapability>
    /// Локальный раннер (Ollama и т.п.) — ключ не нужен, но нужен запущенный процесс.
    let isLocal: Bool
    /// Модель по умолчанию для автоматического роутинга без явного назначения
    /// пользователя (см. FunctionRouter). nil — провайдер не участвует в
    /// автовыборе (например, ключа ещё нет и назначать по умолчанию нечего).
    let defaultModel: String?

    var requiresKey: Bool { !isLocal }

    init(id: ProviderID, displayName: String, capabilities: Set<ProviderCapability>, isLocal: Bool, defaultModel: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.isLocal = isLocal
        self.defaultModel = defaultModel
    }
}

/// Реестр провайдеров: дескрипторы (метаданные) + реализации протоколов.
/// Один на приложение; UI настроек (задача 17) читает `descriptors` для пикеров.
@MainActor
final class ProviderRegistry: ObservableObject {
    @Published private(set) var descriptors: [ProviderDescriptor] = []

    private var chatProviders: [ProviderID: ChatProvider] = [:]
    private var transcriptionProviders: [ProviderID: TranscriptionProvider] = [:]
    private var embeddingProviders: [ProviderID: EmbeddingProvider] = [:]
    /// Проверка «рантайм поднят» для локальных провайдеров — своя на каждый id,
    /// регистрируется вызывающим (09/10 — реальная проверка процесса; без неё
    /// локальный провайдер считается доступным всегда, чтобы не блокировать
    /// разработку до появления менеджера рантайма).
    private var availabilityChecks: [ProviderID: () -> Bool] = [:]

    init() {}

    /// Регистрирует провайдер: дескриптор + любые протокольные реализации,
    /// которые он поддерживает (nil — не поддерживает соответствующий протокол).
    func register(
        _ descriptor: ProviderDescriptor,
        chat: ChatProvider? = nil,
        transcription: TranscriptionProvider? = nil,
        embedding: EmbeddingProvider? = nil,
        isAvailable: (() -> Bool)? = nil
    ) {
        descriptors.removeAll { $0.id == descriptor.id } // повторная регистрация — замена
        descriptors.append(descriptor)
        chatProviders[descriptor.id] = chat
        transcriptionProviders[descriptor.id] = transcription
        embeddingProviders[descriptor.id] = embedding
        if let isAvailable {
            availabilityChecks[descriptor.id] = isAvailable
        }
    }

    func descriptor(for id: ProviderID) -> ProviderDescriptor? {
        descriptors.first { $0.id == id }
    }

    func chatProvider(for id: ProviderID) -> ChatProvider? { chatProviders[id] }
    func transcriptionProvider(for id: ProviderID) -> TranscriptionProvider? { transcriptionProviders[id] }
    func embeddingProvider(for id: ProviderID) -> EmbeddingProvider? { embeddingProviders[id] }

    /// Доступен ли провайдер прямо сейчас: если нужен ключ — он должен быть
    /// в KeyStore; дополнительно спрашиваем зарегистрированную проверку рантайма
    /// (для локальных — жив ли процесс; по умолчанию true).
    func isAvailable(_ id: ProviderID) -> Bool {
        guard let descriptor = descriptor(for: id) else { return false }
        if descriptor.requiresKey && !KeyStore.hasKey(for: id) { return false }
        return availabilityChecks[id]?() ?? true
    }

    /// Провайдеры, поддерживающие способность, в порядке регистрации.
    func descriptors(supporting capability: ProviderCapability) -> [ProviderDescriptor] {
        descriptors.filter { $0.capabilities.contains(capability) }
    }
}
