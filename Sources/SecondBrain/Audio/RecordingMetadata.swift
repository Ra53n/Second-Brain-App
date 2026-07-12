// RecordingMetadata.swift — sidecar-метаданные записи.
//
// Решение: метаданные лежат РЯДОМ с аудиофайлом (<base>.json в _recordings/),
// а не в Application Support — так запись самодостаточна, переживает
// переустановку приложения и уезжает вместе с vault при git-синхронизации
// (задача 16). Формат снисходителен к миграциям (паттерн MigrationTests из MA):
// каждое поле через decodeIfPresent с дефолтом, незнакомый source не роняет
// загрузку.

import Foundation

/// Метаданные одной записи: дата, чистая длительность, режим, файлы дорожек.
struct RecordingMetadata: Codable, Equatable {
    /// Версия схемы — задел под будущие миграции.
    var schemaVersion: Int
    /// Момент начала записи.
    var date: Date
    /// Чистая длительность записи, сек (паузы исключены).
    var duration: TimeInterval
    /// Режим записи.
    var source: RecordingSource
    /// Имена аудиофайлов записи относительно папки sidecar'а (1 или 2 дорожки).
    var files: [String]

    init(schemaVersion: Int = 1,
         date: Date,
         duration: TimeInterval,
         source: RecordingSource,
         files: [String]) {
        self.schemaVersion = schemaVersion
        self.date = date
        self.duration = duration
        self.source = source
        self.files = files
    }

    /// Снисходительный декодер: старый/чужой JSON без части полей грузится с дефолтами.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        // Неизвестное значение source (файл из будущей версии) → дефолт, не ошибка.
        let rawSource = try c.decodeIfPresent(String.self, forKey: .source)
        source = rawSource.flatMap(RecordingSource.init(rawValue:)) ?? .microphone
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
    }
}

/// Чтение/запись sidecar-файлов. Даты — ISO8601, запись атомарная
/// (паттерн персистентности из CONVENTIONS.md).
enum RecordingMetadataStore {
    /// URL sidecar-файла для базового имени записи.
    static func sidecarURL(base: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(base).json")
    }

    static func save(_ metadata: RecordingMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> RecordingMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingMetadata.self, from: Data(contentsOf: url))
    }
}
