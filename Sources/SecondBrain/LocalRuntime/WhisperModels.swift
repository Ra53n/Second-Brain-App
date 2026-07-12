// WhisperModels.swift — каталог и хранение whisper-моделей (задача 10).
//
// Модели скачивает сам WhisperKit с Hugging Face, но downloadBase направлен в
// наш Application Support (~/Library/Application Support/SecondBrain/WhisperKit),
// чтобы UI управления моделями видел файлы и мог их удалять. На диске модели
// лежат в <base>/models/argmaxinc/whisperkit-coreml/openai_whisper-<вариант>.
//
// Чистые функции (пути, скан установленного, маппинг результатов в Transcript)
// отделены от WhisperKit и тестируются без него.

import Foundation

/// Каталог whisper-моделей для UI. Размеры приблизительные (CoreML-варианты).
struct WhisperVariant: Identifiable, Equatable {
    let name: String     // имя варианта для WhisperKit(model:)
    let note: String     // подсказка в UI

    var id: String { name }

    /// tiny → large-v3 + turbo. Рекомендация для Apple Silicon пользователя —
    /// large-v3_turbo: качество large при ~4× скорости; medium — если тесно.
    static let catalog: [WhisperVariant] = [
        WhisperVariant(name: "tiny", note: "~150 МБ, черновое качество"),
        WhisperVariant(name: "base", note: "~300 МБ"),
        WhisperVariant(name: "small", note: "~950 МБ"),
        WhisperVariant(name: "medium", note: "~3 ГБ, хороший русский"),
        WhisperVariant(name: "large-v3", note: "~6 ГБ, максимум качества"),
        WhisperVariant(name: "large-v3_turbo", note: "~3 ГБ, качество large, быстрее в разы — рекомендуем"),
    ]

    static let recommendedName = "large-v3_turbo"
}

enum WhisperModelStorage {
    /// Корень кэша WhisperKit — внутри нашего Application Support.
    static var defaultDownloadBase: URL {
        Config.appSupportDirectory.appendingPathComponent("WhisperKit", isDirectory: true)
    }

    /// Папка, куда HubApi кладёт варианты моделей.
    static func modelsRoot(base: URL) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// Установленные варианты: скан папок вида openai_whisper-<вариант>.
    static func installedVariants(base: URL) -> [String] {
        let root = modelsRoot(base: base)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { variantName(fromFolder: $0.lastPathComponent) }
            .sorted()
    }

    /// «openai_whisper-large-v3_turbo» → «large-v3_turbo».
    static func variantName(fromFolder folder: String) -> String {
        folder.hasPrefix("openai_whisper-")
            ? String(folder.dropFirst("openai_whisper-".count))
            : folder
    }

    /// Установлен ли вариант (папка существует и не пуста).
    static func isInstalled(_ variant: String, base: URL) -> Bool {
        installedVariants(base: base).contains(variant)
    }

    /// Удаление модели с диска: сама папка варианта.
    static func delete(_ variant: String, base: URL) throws {
        let root = modelsRoot(base: base)
        guard let items = try? FileManager.default.contentsOfDirectory(at: root,
                                                                       includingPropertiesForKeys: nil)
        else { return }
        for folder in items where variantName(fromFolder: folder.lastPathComponent) == variant {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Размер варианта на диске (для UI), 0 — не установлен.
    static func sizeOnDisk(_ variant: String, base: URL) -> Int64 {
        let root = modelsRoot(base: base)
        guard let items = try? FileManager.default.contentsOfDirectory(at: root,
                                                                       includingPropertiesForKeys: nil),
              let folder = items.first(where: {
                  variantName(fromFolder: $0.lastPathComponent) == variant
              }),
              let enumerator = FileManager.default.enumerator(at: folder,
                                                              includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - Маппинг результата WhisperKit → Transcript

/// Сегмент из движка (плоский DTO, без типов WhisperKit — тестируемость).
struct WhisperSegmentData: Equatable, Codable {
    var text: String
    var start: Double
    var end: Double
}

/// Выход движка транскрипции.
struct WhisperEngineOutput: Equatable {
    var segments: [WhisperSegmentData]
    var language: String?
}

enum WhisperMapping {
    /// WhisperKit-сегменты → наш Transcript: текст чистится от пробельного
    /// мусора, пустые сегменты выбрасываются, fullText — склейка сегментов.
    static func transcript(from output: WhisperEngineOutput) -> Transcript {
        let segments: [TranscriptSegment] = output.segments.compactMap { raw in
            let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(text: text,
                                     start: raw.start,
                                     end: raw.end >= raw.start ? raw.end : nil)
        }
        let fullText = segments.map(\.text).joined(separator: " ")
        return Transcript(fullText: fullText,
                          segments: segments,
                          language: output.language)
    }
}
