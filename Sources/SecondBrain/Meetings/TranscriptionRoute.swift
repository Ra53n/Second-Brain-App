// TranscriptionRoute.swift — логика чипа «Транскрипция: …» в статус-строке
// раздела «Встречи» (задача 41) и навигация из ошибок пайплайна в настройки.
//
// Presenter — чистая обёртка над FunctionRouter/ProviderRegistry: View только
// рисует то, что он отдал (заголовок чипа, пункты меню), и дёргает select.
// Отдельный тип, а не методы MeetingsViewModel, чтобы тестировать без
// вью-модели (ей нужны VaultManager и аудио-подсистема).

import Foundation

/// Состояние и действия переключателя провайдера транскрипции.
@MainActor
struct TranscriptionRoutePresenter {
    let router: FunctionRouter

    /// Пункт меню: провайдер со способностью .transcription.
    struct Choice: Identifiable, Equatable {
        let id: ProviderID
        let title: String
        let isSelected: Bool   // явное назначение пользователя
        let isAvailable: Bool  // есть ключ / рантайм жив
    }

    /// Явное валидное назначение пользователя (протухшее — как «Авто»).
    private var explicitDescriptor: ProviderDescriptor? {
        guard let assignment = router.assignment(for: .transcription),
              let descriptor = router.registry.descriptor(for: assignment.providerID),
              descriptor.capabilities.contains(.transcription),
              router.registry.isAvailable(descriptor.id) else { return nil }
        return descriptor
    }

    /// Провайдер автодефолта («Авто → X»).
    private var autoDescriptor: ProviderDescriptor? {
        guard let (id, _) = router.defaultAssignment(for: .transcription) else { return nil }
        return router.registry.descriptor(for: id)
    }

    /// Есть ли вообще чем транскрибировать (для баннера и цвета чипа).
    var hasAvailableProvider: Bool {
        explicitDescriptor != nil || autoDescriptor != nil
    }

    /// Подпись чипа в статус-строке.
    var chipTitle: String {
        if let explicit = explicitDescriptor {
            return "Транскрипция: \(explicit.displayName)"
        }
        if let auto = autoDescriptor {
            return "Транскрипция: Авто (\(auto.displayName))"
        }
        return "Транскрипция: нет провайдера"
    }

    /// Все провайдеры транскрипции для меню (недоступные — задизейблены,
    /// но видны: пользователь понимает, что можно включить ключом/моделью).
    var choices: [Choice] {
        let explicitID = router.assignment(for: .transcription)?.providerID
        return router.registry.descriptors(supporting: .transcription).map { descriptor in
            Choice(id: descriptor.id,
                   title: descriptor.displayName,
                   isSelected: descriptor.id == explicitID,
                   isAvailable: router.registry.isAvailable(descriptor.id))
        }
    }

    /// Явное назначение выбрано в меню (модель — дефолтная провайдера).
    func select(_ id: ProviderID) {
        let model = router.registry.descriptor(for: id)?.defaultModel(for: .transcription) ?? ""
        router.assign(FunctionAssignment(providerID: id, model: model), to: .transcription)
    }

    /// «Авто» — снять явное назначение, вернуться к автодефолту роутера.
    func selectAuto() {
        router.clearAssignment(for: .transcription)
    }
}

/// Навигация из ошибок пайплайна встречи: по тексту ошибки — вкладка настроек,
/// где её чинить. nil — ошибка не про настройки (кнопку не показываем).
enum MeetingErrorNavigation {
    static func settingsTab(forErrorText text: String) -> SettingsTab? {
        if text == MeetingError.noTranscriptionProvider.errorDescription { return .providers }
        if text == MeetingError.noChatProvider.errorDescription { return .providers }
        return nil
    }
}
