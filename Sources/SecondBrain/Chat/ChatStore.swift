// ChatStore.swift — персистентность истории чатов (порт ChatStore из MA).
//
// Файл: ~/Library/Application Support/SecondBrain/chats.json. Правила
// (CONVENTIONS.md): атомарная запись; битый файл → chats.corrupt.json, не
// роняя приложение; runtime-поля (isLoading, errorText) не сохраняются
// (см. Chat.CodingKeys). Автосохранение с debounce — в ChatViewModel.

import Foundation

enum ChatPersistence {
    static var defaultFileURL: URL {
        Config.appSupportDirectory.appendingPathComponent("chats.json")
    }

    /// Загружает чаты; отсутствие файла или повреждение → пустой список
    /// (повреждённый файл откладывается в карантин).
    static func load(from url: URL = defaultFileURL) -> [Chat] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([Chat].self, from: data)
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    /// Атомарно записывает все чаты на диск.
    static func save(_ chats: [Chat], to url: URL = defaultFileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(chats) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
