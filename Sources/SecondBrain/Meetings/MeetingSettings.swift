// MeetingSettings.swift — настройки пайплайна встреч.
//
// Пока единственная настройка — пользовательские правила раскладки (текст,
// подставляемый в [USER_RULES] summary-промпта: «встречи 1:1 клади в
// Управление командой/1на1»). Хранится в Application Support; экран настроек
// (задача 17) позже заберёт это поле к себе — формат уже миграционно-устойчив.

import Foundation

struct MeetingSettings: Codable, Equatable {
    /// Правила раскладки для LLM ([USER_RULES]); пустая строка — дефолт
    /// (Meetings/YYYY-MM).
    var filingRules: String = ""

    enum CodingKeys: String, CodingKey { case filingRules }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filingRules = try c.decodeIfPresent(String.self, forKey: .filingRules) ?? ""
    }
}

enum MeetingSettingsStore {
    static var defaultFileURL: URL {
        Config.appSupportDirectory.appendingPathComponent("meeting_settings.json")
    }

    static func load(from url: URL = defaultFileURL) -> MeetingSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(MeetingSettings.self, from: data)
        else { return MeetingSettings() }
        return settings
    }

    static func save(_ settings: MeetingSettings, to url: URL = defaultFileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
