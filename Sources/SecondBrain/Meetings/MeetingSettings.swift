// MeetingSettings.swift — настройки пайплайна встреч.
//
// Хранится в Application Support (meeting_settings.json); редактируется в двух
// местах — разделе «Встречи» (правила раскладки) и окне настроек (задача 17).
// Все записи — ТОЛЬКО через load-modify-save: файл общий, слепая перезапись
// новым экземпляром стирала бы чужие поля. Формат миграционно-устойчив
// (decodeIfPresent с дефолтами).

import Foundation

struct MeetingSettings: Codable, Equatable {
    /// Правила раскладки для LLM ([USER_RULES]); пустая строка — дефолт
    /// (Meetings/YYYY-MM).
    var filingRules: String = ""
    /// Папка по умолчанию для заметок встреч (фолбэк, когда LLM не предложил
    /// валидную); пустая строка — Meetings/YYYY-MM.
    var defaultFolder: String = ""
    /// Источник записи, предвыбранный при запуске; nil — микрофон.
    var defaultSource: RecordingSource?

    enum CodingKeys: String, CodingKey { case filingRules, defaultFolder, defaultSource }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filingRules = try c.decodeIfPresent(String.self, forKey: .filingRules) ?? ""
        defaultFolder = try c.decodeIfPresent(String.self, forKey: .defaultFolder) ?? ""
        defaultSource = try c.decodeIfPresent(RecordingSource.self, forKey: .defaultSource)
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

    /// Точечное изменение: load-modify-save одним вызовом — чтобы редакторы
    /// разных полей (раздел «Встречи», окно настроек) не стирали друг друга.
    static func update(at url: URL = defaultFileURL, _ mutate: (inout MeetingSettings) -> Void) {
        var settings = load(from: url)
        mutate(&settings)
        save(settings, to: url)
    }
}
