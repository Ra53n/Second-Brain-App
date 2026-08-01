// TuningChatStore.swift — персистентность мини-чата тюнинга (задача 85, P2, образец —
// Chat/ChatStore.swift): атомарная запись, карантин битого файла в
// finetune-chat.corrupt.json, снисходительный декодер.

import Foundation

/// baseline/тюн — общий вариант модели для чата и батч-прогона.
enum FineTuneModelVariant: String, Codable, Equatable, CaseIterable {
    case baseline, tuned
}

struct TuningChatMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var role: String
    var content: String
    var report: ConfidenceReport?
    var modelVariant: String?
    var createdAt: Date

    init(id: UUID = UUID(), role: String, content: String, report: ConfidenceReport? = nil,
         modelVariant: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.report = report
        self.modelVariant = modelVariant
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "user"
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        report = try c.decodeIfPresent(ConfidenceReport.self, forKey: .report)
        modelVariant = try c.decodeIfPresent(String.self, forKey: .modelVariant)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct TuningChatDocument: Codable, Equatable {
    var messages: [TuningChatMessage]
    var modelVariant: String
    var pipelineConfig: ConfidencePipelineConfig

    init(messages: [TuningChatMessage] = [], modelVariant: String = FineTuneModelVariant.baseline.rawValue,
         pipelineConfig: ConfidencePipelineConfig = .default) {
        self.messages = messages
        self.modelVariant = modelVariant
        self.pipelineConfig = pipelineConfig
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([TuningChatMessage].self, forKey: .messages) ?? []
        modelVariant = try c.decodeIfPresent(String.self, forKey: .modelVariant) ?? FineTuneModelVariant.baseline.rawValue
        pipelineConfig = try c.decodeIfPresent(ConfidencePipelineConfig.self, forKey: .pipelineConfig) ?? .default
    }
}

enum TuningChatPersistence {
    static var defaultFileURL: URL {
        Config.appSupportDirectory.appendingPathComponent("finetune-chat.json")
    }

    /// Отсутствие/повреждение файла → пустой документ (битый откладывается в карантин).
    static func load(from url: URL = defaultFileURL) -> TuningChatDocument {
        guard let data = try? Data(contentsOf: url) else { return TuningChatDocument() }
        do {
            return try JSONDecoder().decode(TuningChatDocument.self, from: data)
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return TuningChatDocument()
        }
    }

    static func save(_ document: TuningChatDocument, to url: URL = defaultFileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
