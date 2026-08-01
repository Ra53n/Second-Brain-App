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
    /// База чата (задача 92): nil → `MlxServerConfig.defaultModel` (легаси-7B) — решает VM,
    /// не документ, иначе тесты миграции пришлось бы дублировать в двух местах.
    var chatBaseModel: String?

    /// Документы до задачи 92 знали только 7B — на неё же мигрируют легаси-ключи тредов.
    /// `MlxServerConfig` в том же таргете, дублировать строку незачем.
    private static let legacyBaseModel = MlxServerConfig.defaultModel

    init(threads: [String: TuningChatThread] = [:], modelVariant: String = FineTuneModelVariant.baseline.rawValue,
         escalationTarget: EscalationTarget? = nil, chatBaseModel: String? = nil) {
        self.threads = threads
        self.modelVariant = modelVariant
        self.escalationTarget = escalationTarget
        self.chatBaseModel = chatBaseModel
    }

    /// Миграция задачи 89: старый плоский документ (`messages`/`pipelineConfig` на
    /// верхнем уровне) не терял историю — она целиком уезжает в тред `modelVariant`,
    /// конфиг копируется в оба треда, чтобы второй вариант не грузился с чужого дефолта.
    /// Незнакомый вариант в `threads` («значение из будущего») декодируется в словарь
    /// как есть (ключ — `String`, не enum) — падения нет, известные треды целы.
    ///
    /// Миграция задачи 92: ключ треда становится `"<variant>|<model>"` — легаси-ключи
    /// `baseline`/`tuned` (плоские, без `|`) переименовываются на 7B, известную единственную
    /// базу до этой задачи.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelVariant = try c.decodeIfPresent(String.self, forKey: .modelVariant) ?? FineTuneModelVariant.baseline.rawValue
        escalationTarget = try c.decodeIfPresent(EscalationTarget.self, forKey: .escalationTarget)
        chatBaseModel = try c.decodeIfPresent(String.self, forKey: .chatBaseModel)
        if let decodedThreads = try c.decodeIfPresent([String: TuningChatThread].self, forKey: .threads) {
            threads = TuningChatDocument.migrateLegacyThreadKeys(decodedThreads)
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
            "\(FineTuneModelVariant.baseline.rawValue)|\(Self.legacyBaseModel)": TuningChatThread(pipelineConfig: pipelineConfig),
            "\(FineTuneModelVariant.tuned.rawValue)|\(Self.legacyBaseModel)": TuningChatThread(pipelineConfig: pipelineConfig),
        ]
        migrated["\(modelVariant)|\(Self.legacyBaseModel)"] = TuningChatThread(messages: messages, pipelineConfig: pipelineConfig)
        threads = migrated
    }

    /// Ключи `"baseline"`/`"tuned"` (до задачи 92, единственная база — 7B) → `"…|<7B>"`;
    /// уже мигрированные (`|` в ключе) или незнакомые ключи проходят как есть.
    private static func migrateLegacyThreadKeys(
        _ threads: [String: TuningChatThread]
    ) -> [String: TuningChatThread] {
        var migrated: [String: TuningChatThread] = [:]
        for (key, thread) in threads {
            if key == FineTuneModelVariant.baseline.rawValue || key == FineTuneModelVariant.tuned.rawValue {
                migrated["\(key)|\(legacyBaseModel)"] = thread
            } else {
                migrated[key] = thread
            }
        }
        return migrated
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(threads, forKey: .threads)
        try c.encode(modelVariant, forKey: .modelVariant)
        try c.encodeIfPresent(escalationTarget, forKey: .escalationTarget)
        try c.encodeIfPresent(chatBaseModel, forKey: .chatBaseModel)
    }

    private enum CodingKeys: String, CodingKey {
        case threads, modelVariant, messages, pipelineConfig, escalationTarget, chatBaseModel
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
