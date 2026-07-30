// DeepLink.swift — навигация по URL-схеме secondbrain:// (задача 50).
//
// Здесь живут:
//  - DeepLink       — маршрут: раздел приложения или вкладка настроек;
//  - DeepLinkParser — чистый разбор URL → маршрут (без побочных эффектов).
//
// Поток данных: `open "secondbrain://section/meetings"` → macOS → onOpenURL
// в ContentView → DeepLinkParser.parse → переключение раздела или
// SettingsTabRouter.open.
//
// Зачем: AX-клик по строке сайдбара переключает раздел ненадёжно (задача 49),
// из-за чего смоук UI был недетерминированным. Ссылка работает всегда.
//
// Важно: URL — НЕДОВЕРЕННЫЙ ввод, открыть его может любое приложение или
// веб-страница. Поэтому схема умеет только навигацию: ни записи, ни удаления,
// ни запуска пайплайнов сюда добавлять нельзя.

import Foundation

/// Куда ведёт ссылка.
enum DeepLink: Equatable {
    /// Раздел главного окна.
    case section(AppSection)
    /// Окно настроек на конкретной вкладке.
    case settings(SettingsTab)
}

/// Разбор `secondbrain://…`. Всё, что не распознано, — nil: приложение молчит,
/// а не показывает ошибку на каждый мусорный URL.
enum DeepLinkParser {
    /// Схема из CFBundleURLTypes (run.sh обязан использовать ту же).
    static let scheme = "secondbrain"

    /// URL → маршрут. nil — чужая схема, неизвестный хост или слаг.
    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // «secondbrain://section/meetings» → host = section, первый компонент пути.
        let host = (url.host ?? "").lowercased()
        let value = url.pathComponents.first(where: { $0 != "/" }) ?? ""
        guard !value.isEmpty else { return nil }

        switch host {
        case "section":
            guard let section = AppSection(slug: value) else { return nil }
            return .section(section)
        case "settings":
            // rawValue вкладок — camelCase (localModels), поэтому сравниваем
            // без учёта регистра: в ссылке удобнее писать localmodels.
            guard let tab = SettingsTab.allCases.first(
                where: { $0.rawValue.lowercased() == value.lowercased() }
            ) else { return nil }
            return .settings(tab)
        default:
            return nil
        }
    }
}

extension AppSection {
    /// Английский идентификатор для ссылок. rawValue — русская подпись в UI,
    /// её нельзя тащить в контракт URL: перевод изменится — ссылки отвалятся.
    var slug: String {
        switch self {
        case .notes: return "notes"
        case .meetings: return "meetings"
        case .chat: return "chat"
        case .pipelines: return "pipelines"
        case .finetune: return "finetune"
        case .settings: return "settings"
        }
    }

    /// Раздел по идентификатору из ссылки (регистр не важен).
    init?(slug: String) {
        let normalized = slug.lowercased()
        guard let match = AppSection.allCases.first(where: { $0.slug == normalized }) else {
            return nil
        }
        self = match
    }
}

extension Notification.Name {
    /// «Открыть раздел» (object — AppSection). Шлёт обработчик ссылок.
    static let openSection = Notification.Name("com.local.second-brain.openSection")
}
