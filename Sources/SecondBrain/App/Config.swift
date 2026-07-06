// Config.swift — базовая конфигурация приложения.
//
// Каркас (задача 01): пока только идентичность приложения; настройки
// провайдеров/vault появятся в задачах 07 и 17. API-ключи здесь не живут
// никогда — только Keychain + env (см. CONVENTIONS.md «Секреты»).

import Foundation

/// Базовые константы приложения. Единая точка правды для имени и bundle id —
/// их же использует run.sh при генерации Info.plist.
enum Config {
    /// Отображаемое имя приложения (заголовок окна, CFBundleDisplayName).
    static let appName = "Second Brain"

    /// Bundle identifier собранного .app (run.sh обязан использовать тот же).
    static let bundleID = "com.local.second-brain"

    /// Папка производных данных (индексы, кэши) — вне vault, пересоздаваема.
    /// Инвариант №1: vault — источник истины, всё остальное можно удалить.
    static var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondBrain", isDirectory: true)
    }
}
