// StagedInference.swift — чистое ядро декомпозиции primary-запроса чата тюнинга на
// цепочку стадий (задача 94): говорящие → задачи с исполнителями → сроки → сборка.

import Foundation

/// Одна стадия цепочки: имя для прогресса/бейджа + промпт с плейсхолдерами
/// `{{transcript}}`, `{{prev}}`, `{{stage:N}}`.
struct InferenceStage: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var prompt: String

    init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }
}

/// Замер одной стадии — для разбивки в `ConfidenceReport.stages`.
struct StageMetric: Equatable, Codable {
    var name: String
    var latency: TimeInterval
    var promptTokens: Int
    var completionTokens: Int
    var parseOk: Bool

    init(name: String, latency: TimeInterval, promptTokens: Int, completionTokens: Int, parseOk: Bool) {
        self.name = name
        self.latency = latency
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.parseOk = parseOk
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        latency = try c.decodeIfPresent(TimeInterval.self, forKey: .latency) ?? 0
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        parseOk = try c.decodeIfPresent(Bool.self, forKey: .parseOk) ?? true
    }
}

/// Что использует `ConfidencePipeline` для primary-запроса: один вызов
/// `[system, transcript]` (как раньше) или цепочка стадий.
enum PrimaryStrategy: Equatable {
    case monolithic
    case staged([InferenceStage])
}

enum StagedInferenceCore {
    /// Дефолтная декомпозиция по полям итогового `{"action_items": [...]}`: каждая стадия
    /// дешёвая и узкая, финальная несёт правила `finetune/meetings/system_prompt.txt`.
    static func defaultStages() -> [InferenceStage] {
        [
            InferenceStage(name: "Говорящие", prompt: """
            Ниже — фрагмент расшифровки рабочей встречи. Перечисли всех, кто говорит или \
            упоминается как участник обсуждения (роль или имя, как названы во фрагменте).

            Фрагмент встречи:
            {{transcript}}

            Ответь СТРОГО одним JSON-объектом без пояснений и без markdown-обёртки:
            {"speakers": ["роль или имя", ...]}
            """),
            InferenceStage(name: "Задачи и исполнители", prompt: """
            Ниже — фрагмент расшифровки рабочей встречи и список говорящих, определённый на \
            предыдущем шаге.

            Фрагмент встречи:
            {{transcript}}

            Говорящие:
            {{stage:1}}

            Выдели поручения — явно прозвучавшие договорённости о том, что кто-то сделает \
            конкретную работу. Обсуждение, мнение, вопрос, идея без принятого решения \
            поручением не являются. Для каждого поручения укажи assignee (роль или имя \
            исполнителя из списка говорящих либо null, если исполнитель не назван или работа \
            поручена всем сразу) и task (что именно нужно сделать, короткой фразой).

            Ответь СТРОГО одним JSON-объектом без пояснений и без markdown-обёртки:
            {"tasks": [{"assignee": ..., "task": ...}, ...]}
            """),
            InferenceStage(name: "Сроки", prompt: """
            Ниже — фрагмент расшифровки рабочей встречи и список поручений, определённых на \
            предыдущем шаге.

            Фрагмент встречи:
            {{transcript}}

            Поручения:
            {{stage:2}}

            Для каждого поручения (в том же порядке) укажи due — срок, если он прозвучал \
            дословно во фрагменте, иначе null. Ничего не додумывай: не подставляй срок, \
            которого не было.

            Ответь СТРОГО одним JSON-объектом без пояснений и без markdown-обёртки:
            {"deadlines": [{"task": ..., "due": ...}, ...]}
            """),
            InferenceStage(name: "Сборка", prompt: """
            Ниже — фрагмент расшифровки рабочей встречи и промежуточные результаты разбора: \
            говорящие, поручения с исполнителями, сроки.

            Фрагмент встречи:
            {{transcript}}

            Говорящие:
            {{stage:1}}

            Поручения и исполнители:
            {{stage:2}}

            Сроки:
            {{stage:3}}

            Собери итоговый список поручений. Для каждого укажи: assignee — роль или имя \
            того, кто назван исполнителем, либо null, если исполнитель не назван или работа \
            поручена всем сразу; task — что именно нужно сделать, короткой фразой; due — срок, \
            если он прозвучал дословно, иначе null. Ничего не додумывай: не выводи исполнителя \
            из контекста и не подставляй срок, которого не было. Если поручений нет, верни \
            пустой список.

            Ответь ТОЛЬКО JSON вида {"action_items": [{"assignee": ..., "task": ..., "due": ...}]}, \
            без пояснений и без markdown-обёртки.
            """),
        ]
    }

    /// `{{transcript}}` — фрагмент встречи; `{{prev}}` — выход предыдущей стадии ("" у
    /// первой); `{{stage:N}}` (1-based) — выход стадии N, вне диапазона остаётся литералом.
    /// Оговорка: подстановки идут последовательно, поэтому литеральный плейсхолдер внутри
    /// самого транскрипта или выхода стадии развернётся следующим проходом — для чата
    /// тюнинга (реальные расшифровки встреч) приемлемо.
    static func renderPrompt(_ template: String, transcript: String, previousOutputs: [String]) -> String {
        var result = template.replacingOccurrences(of: "{{transcript}}", with: transcript)
        result = result.replacingOccurrences(of: "{{prev}}", with: previousOutputs.last ?? "")
        for index in previousOutputs.indices {
            result = result.replacingOccurrences(of: "{{stage:\(index + 1)}}", with: previousOutputs[index])
        }
        return result
    }

    /// Первый JSON-объект из ответа модели → compact-текст на вход следующей стадии;
    /// не нашёлся — trim сырого текста, `parseOk=false` (не роняет цепочку, P6 сигналом
    /// уровнем выше).
    static func compactOutput(_ raw: String) -> (text: String, parseOk: Bool) {
        if let object = ConfidencePrompts.firstJSONObjectString(raw) {
            return (object, true)
        }
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), false)
    }

    /// Стадии с пустым (после trim) промптом исключены из прогона — редактор не даёт их
    /// сохранить, это второй рубеж (belt and suspenders).
    static func effectiveStages(_ stages: [InferenceStage]) -> [InferenceStage] {
        stages.filter { !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Совпадение с дефолтным шаблоном по (name, prompt), без учёта `id`: редактор,
    /// вернувший draft к исходным текстам, сохраняет `nil` («не редактировал»), а не
    /// заморозку текущего шаблона — правки будущего шаблона доходят до документа.
    static func matchesDefault(_ stages: [InferenceStage]) -> Bool {
        let template = defaultStages()
        guard stages.count == template.count else { return false }
        return zip(stages, template).allSatisfy { $0.name == $1.name && $0.prompt == $1.prompt }
    }
}

/// Склонение существительного при числительном: 1 стадия, 2 стадии, 5 стадий
/// (11–14 — всегда третья форма).
enum RussianPlural {
    static func form(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n = abs(count) % 100
        if (11...14).contains(n) { return many }
        switch n % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }
}
