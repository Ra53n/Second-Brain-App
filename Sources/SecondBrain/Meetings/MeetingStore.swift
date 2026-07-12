// MeetingStore.swift — персистентность контекстов встреч (паттерн ChatStore из MA).
//
// Файл: ~/Library/Application Support/SecondBrain/meetings.json.
// Правила (CONVENTIONS.md):
//  - запись атомарная; битый файл переезжает в meetings.corrupt.json, не роняя
//    приложение;
//  - автосохранение с debounce 300 мс на @Published-поле;
//  - persistNow() — синхронная запись после каждого FSM-перехода (crash-safety);
//  - normalize() на старте: зависшие running → paused (живых Task после
//    рестарта нет, прогон остаётся возобновляемым кнопкой «Продолжить»).

import Combine
import Foundation

/// Чтение/запись списка встреч (чистые функции, URL инжектируется для тестов).
enum MeetingPersistence {
    static var defaultFileURL: URL {
        Config.appSupportDirectory.appendingPathComponent("meetings.json")
    }

    static func load(from url: URL) -> [MeetingContext] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([MeetingContext].self, from: data)
        } catch {
            // Битый файл — в карантин, стартуем с пустого (не роняем приложение).
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    static func save(_ meetings: [MeetingContext], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(meetings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Владелец списка встреч в рантайме.
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [MeetingContext] = []

    private let fileURL: URL
    private var saveCancellable: AnyCancellable?

    init(fileURL: URL = MeetingPersistence.defaultFileURL) {
        self.fileURL = fileURL
        meetings = MeetingPersistence.load(from: fileURL)
        normalize()
        // Автосохранение при любом изменении; debounce гасит шквал обновлений.
        saveCancellable = $meetings
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [fileURL] meetings in
                DispatchQueue.global(qos: .utility).async {
                    MeetingPersistence.save(meetings, to: fileURL)
                }
            }
    }

    /// Синхронная запись без debounce — после каждого FSM-перехода (crash-safety).
    func persistNow() {
        MeetingPersistence.save(meetings, to: fileURL)
    }

    func context(id: UUID) -> MeetingContext? {
        meetings.first { $0.id == id }
    }

    /// Контекст встречи по базовому имени записи (связь со списком записей 06).
    func context(forRecordingBase base: String) -> MeetingContext? {
        meetings.first { $0.recordingBase == base }
    }

    /// Вставка нового или замена существующего контекста + немедленная запись.
    func upsert(_ context: MeetingContext) {
        if let index = meetings.firstIndex(where: { $0.id == context.id }) {
            meetings[index] = context
        } else {
            meetings.append(context)
        }
        persistNow()
    }

    /// Мутация контекста на месте + немедленная запись. Возвращает false,
    /// если контекст уже удалён.
    @discardableResult
    func mutate(id: UUID, _ change: (inout MeetingContext) -> Void) -> Bool {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return false }
        change(&meetings[index])
        persistNow()
        return true
    }

    func remove(id: UUID) {
        meetings.removeAll { $0.id == id }
        persistNow()
    }

    /// Зависшие «в работе» прогоны после рестарта → paused: живых Task нет,
    /// прогон должен остаться возобновляемым, а не «висеть» вечно.
    private func normalize() {
        var changed = false
        for index in meetings.indices where meetings[index].status == .running {
            meetings[index].status = .paused
            changed = true
        }
        if changed { persistNow() }
    }
}
