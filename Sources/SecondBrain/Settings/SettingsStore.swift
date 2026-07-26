// SettingsStore.swift — единый стор настроек приложения (задача 17).
//
// Собирает «россыпь» значений, до этого живших в UserDefaults по разным
// ключам, в один Codable-файл settings.json (паттерн ChatStore: атомарная
// запись, битый файл в карантин, снисходительное декодирование). Специализи-
// рованные сторы (роутинг моделей, MCP-серверы, настройки встреч, ключи в
// Keychain) остаются на месте — они уже соответствуют конвенциям; сюда
// переезжают только одиночные флаги/числа.
//
// Миграция: при первом запуске без settings.json значения подтягиваются из
// старых мест (UserDefaults `gitSync.autoBackupMinutes` задачи 16) — ничего
// не сбрасывается. RoutingValidator внизу — чистая валидация назначений
// «функция → провайдер» для предупреждений на вкладке «Модели».

import Foundation
import Combine

/// Все «одиночные» настройки приложения. Новые поля добавлять со значением
/// по умолчанию и decodeIfPresent — старый settings.json обязан загружаться.
struct AppSettings: Codable, Equatable {
    /// Показывать dot-папки (.obsidian, .git…) в дереве vault.
    var showsDotItems = false
    /// Открывать последний vault при запуске приложения.
    var restoreLastVault = true
    /// Интервал авто-бэкапа git в минутах; 0 — выключен (задача 16).
    var autoBackupMinutes = 0
    /// Idle-таймаут локальных рантаймов (Ollama-процесс, WhisperKit-модель
    /// в памяти), минуты. Дефолт 10 — как в ARCHITECTURE.md.
    var localIdleMinutes = 10
    /// Корень репозитория для встроенных инструментов проекта в чате
    /// (задача 21). Пусто — инструменты недоступны. Хранится строкой:
    /// приложение не в sandbox, security-scoped bookmark не нужен.
    var projectRepoPath = ""
    /// Бюджет контекста для /help (символы, ~4 на токен). Дефолт 32000 = ~8 тыс.
    /// токенов. Задача 80.
    var helpContextBudget = 32_000

    /// Допустимые границы `helpContextBudget` — общие для UI-валидации и декодирования.
    static let helpContextBudgetRange = 1_000...1_000_000

    enum CodingKeys: String, CodingKey {
        case showsDotItems, restoreLastVault, autoBackupMinutes, localIdleMinutes
        case projectRepoPath, helpContextBudget
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        showsDotItems = try c.decodeIfPresent(Bool.self, forKey: .showsDotItems) ?? d.showsDotItems
        restoreLastVault = try c.decodeIfPresent(Bool.self, forKey: .restoreLastVault) ?? d.restoreLastVault
        autoBackupMinutes = try c.decodeIfPresent(Int.self, forKey: .autoBackupMinutes) ?? d.autoBackupMinutes
        localIdleMinutes = try c.decodeIfPresent(Int.self, forKey: .localIdleMinutes) ?? d.localIdleMinutes
        projectRepoPath = try c.decodeIfPresent(String.self, forKey: .projectRepoPath) ?? d.projectRepoPath
        // Битый/устаревший settings.json может содержать значение за границами —
        // зажимаем при декодировании, а не только при вводе в UI.
        let rawHelpContextBudget = try c.decodeIfPresent(Int.self, forKey: .helpContextBudget) ?? d.helpContextBudget
        let range = AppSettings.helpContextBudgetRange
        helpContextBudget = min(max(rawHelpContextBudget, range.lowerBound), range.upperBound)
    }
}

/// Владелец настроек: загрузка с миграцией, автосохранение на изменение.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
        }
    }

    /// Старый ключ интервала авто-бэкапа (задача 16 хранила в UserDefaults).
    static let legacyAutoBackupKey = "gitSync.autoBackupMinutes"

    nonisolated static var defaultFileURL: URL {
        Config.appSupportDirectory.appendingPathComponent("settings.json")
    }

    private let fileURL: URL

    /// - Parameters:
    ///   - fileURL/defaults: подменяются в тестах (temp-файл, отдельный suite).
    init(fileURL: URL = defaultFileURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            if let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
                settings = loaded
            } else {
                // Битый файл в карантин, стартуем с дефолтов (паттерн ChatStore).
                let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: fileURL, to: backup)
                settings = AppSettings()
                persist()
            }
        } else {
            // Первый запуск после обновления: подтянуть значения из старых мест.
            settings = Self.migrateLegacy(defaults: defaults)
            persist()
        }
    }

    /// Сбор значений из старых мест хранения — ничего не сбрасываем.
    static func migrateLegacy(defaults: UserDefaults) -> AppSettings {
        var settings = AppSettings()
        if defaults.object(forKey: legacyAutoBackupKey) != nil {
            settings.autoBackupMinutes = defaults.integer(forKey: legacyAutoBackupKey)
        }
        return settings
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Валидация роутинга «функция → модель»

/// Проблема явного назначения функции — предупреждение на вкладке «Модели».
/// Назначение с проблемой не ломает приложение (FunctionRouter прозрачно
/// падает на автодефолт), но пользователь должен видеть, что его выбор
/// сейчас не действует.
struct RoutingIssue: Equatable, Identifiable {
    let function: AppFunction
    let message: String
    var id: String { function.rawValue }
}

enum RoutingValidator {
    /// Проверяет каждое явное назначение: провайдер существует, поддерживает
    /// нужную способность и доступен прямо сейчас (ключ есть / рантайм жив).
    @MainActor
    static func issues(config: FunctionRoutingConfig, registry: ProviderRegistry) -> [RoutingIssue] {
        AppFunction.allCases.compactMap { function in
            guard let assignment = config[function] else { return nil } // автодефолт — ок
            guard let descriptor = registry.descriptor(for: assignment.providerID) else {
                return RoutingIssue(function: function,
                                    message: "провайдер «\(assignment.providerID)» не найден — действует автодефолт")
            }
            guard descriptor.capabilities.contains(function.requiredCapability) else {
                return RoutingIssue(function: function,
                                    message: "«\(descriptor.displayName)» не поддерживает эту функцию — действует автодефолт")
            }
            guard registry.isAvailable(assignment.providerID) else {
                return RoutingIssue(function: function,
                                    message: "«\(descriptor.displayName)» недоступен (нет ключа или рантайм не запущен) — действует автодефолт")
            }
            return nil
        }
    }
}
