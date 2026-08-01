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
    var escalation: EscalationRecord?

    init(id: UUID = UUID(), role: String, content: String, report: ConfidenceReport? = nil,
         modelVariant: String? = nil, createdAt: Date = Date(), escalation: EscalationRecord? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.report = report
        self.modelVariant = modelVariant
        self.createdAt = createdAt
        self.escalation = escalation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "user"
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        report = try c.decodeIfPresent(ConfidenceReport.self, forKey: .report)
        modelVariant = try c.decodeIfPresent(String.self, forKey: .modelVariant)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        escalation = try c.decodeIfPresent(EscalationRecord.self, forKey: .escalation)
    }
}

/// История и тумблеры пайплайна одного варианта модели (задача 89) — ключ в
/// `TuningChatDocument.threads` это `FineTuneModelVariant.rawValue`.
struct TuningChatThread: Codable, Equatable {
    var messages: [TuningChatMessage]
    var pipelineConfig: ConfidencePipelineConfig
    var escalationEnabled: Bool

    init(messages: [TuningChatMessage] = [], pipelineConfig: ConfidencePipelineConfig = .default,
         escalationEnabled: Bool = false) {
        self.messages = messages
        self.pipelineConfig = pipelineConfig
        self.escalationEnabled = escalationEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([TuningChatMessage].self, forKey: .messages) ?? []
        pipelineConfig = try c.decodeIfPresent(ConfidencePipelineConfig.self, forKey: .pipelineConfig) ?? .default
        escalationEnabled = try c.decodeIfPresent(Bool.self, forKey: .escalationEnabled) ?? false
    }
}

struct TuningChatDocument: Codable, Equatable {
    var threads: [String: TuningChatThread]
    var modelVariant: String
    /// Доверенная сильная модель эскалации — свойство окружения, не варианта:
    /// per-document, а не per-thread (иначе настраивать дважды).
    var escalationTarget: EscalationTarget?

    init(threads: [String: TuningChatThread] = [:], modelVariant: String = FineTuneModelVariant.baseline.rawValue,
         escalationTarget: EscalationTarget? = nil) {
        self.threads = threads
        self.modelVariant = modelVariant
        self.escalationTarget = escalationTarget
    }

    /// Миграция задачи 89: старый плоский документ (`messages`/`pipelineConfig` на
    /// верхнем уровне) не терял историю — она целиком уезжает в тред `modelVariant`,
    /// конфиг копируется в оба треда, чтобы второй вариант не грузился с чужого дефолта.
    /// Незнакомый вариант в `threads` («значение из будущего») декодируется в словарь
    /// как есть (ключ — `String`, не enum) — падения нет, известные треды целы.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelVariant = try c.decodeIfPresent(String.self, forKey: .modelVariant) ?? FineTuneModelVariant.baseline.rawValue
        escalationTarget = try c.decodeIfPresent(EscalationTarget.self, forKey: .escalationTarget)
        if let decodedThreads = try c.decodeIfPresent([String: TuningChatThread].self, forKey: .threads) {
            threads = decodedThreads
            return
        }
        let messages = try c.decodeIfPresent([TuningChatMessage].self, forKey: .messages) ?? []
        let pipelineConfig = try c.decodeIfPresent(ConfidencePipelineConfig.self, forKey: .pipelineConfig) ?? .default
        // `{}` (или отсутствующий файл) не должен раздуваться в два синтетических
        // дефолтных треда — по-настоящему пустой документ остаётся пустым.
        // Плоский документ с незнакомым modelVariant («из будущего») мигрирует в тред
        // этого ключа: история цела на диске, но невидима, пока VM не узнает вариант.
        guard !messages.isEmpty || pipelineConfig != .default else {
            threads = [:]
            return
        }
        var migrated: [String: TuningChatThread] = [
            FineTuneModelVariant.baseline.rawValue: TuningChatThread(pipelineConfig: pipelineConfig),
            FineTuneModelVariant.tuned.rawValue: TuningChatThread(pipelineConfig: pipelineConfig),
        ]
        migrated[modelVariant] = TuningChatThread(messages: messages, pipelineConfig: pipelineConfig)
        threads = migrated
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(threads, forKey: .threads)
        try c.encode(modelVariant, forKey: .modelVariant)
        try c.encodeIfPresent(escalationTarget, forKey: .escalationTarget)
    }

    private enum CodingKeys: String, CodingKey {
        case threads, modelVariant, messages, pipelineConfig, escalationTarget
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
