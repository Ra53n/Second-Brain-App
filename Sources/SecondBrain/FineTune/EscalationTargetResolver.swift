// EscalationTargetResolver.swift — единственная точка контакта каскадной эскалации
// (задача 91) с ProviderRegistry: цель пользователя → готовый к вызову провайдер
// или русская причина недоступности (P6).

import Foundation

enum EscalationResolution {
    case resolved(ResolvedChatProvider)
    case unavailable(reason: String)
}

@MainActor
enum EscalationTargetResolver {
    static func resolve(target: EscalationTarget?, registry: ProviderRegistry) -> EscalationResolution {
        guard let target else {
            return .unavailable(reason: "модель эскалации не выбрана")
        }
        guard let descriptor = registry.descriptor(for: target.providerID), registry.isAvailable(target.providerID) else {
            return .unavailable(reason: "провайдер «\(target.providerID.rawValue)» недоступен")
        }
        guard let provider = registry.chatProvider(for: target.providerID) else {
            return .unavailable(reason: "провайдер «\(descriptor.displayName)» недоступен")
        }

        let model: String
        if target.model.isEmpty {
            guard let defaultModel = registry.preferredDefaultModel(for: target.providerID, capability: .chat) else {
                return .unavailable(reason: "у провайдера «\(descriptor.displayName)» нет пригодной модели")
            }
            model = defaultModel
        } else {
            guard registry.isModelSelectable(target.model, for: target.providerID, capability: .chat) else {
                return .unavailable(reason: "модель «\(target.model)» недоступна у «\(descriptor.displayName)»")
            }
            model = target.model
        }

        return .resolved(ResolvedChatProvider(provider: provider, model: model,
                                               providerID: target.providerID, displayName: descriptor.displayName))
    }
}
