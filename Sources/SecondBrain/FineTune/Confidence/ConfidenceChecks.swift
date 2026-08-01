// ConfidenceChecks.swift — constraint-проверки ответа модели (задача 85).
// `referenceBased` — порт `run_checks()` из finetune/actionitem_checks.py; `referenceFree` —
// вариант без эталона для мини-чата (эталона там по определению нет).

import Foundation

/// Сохраняет семантику `ok=None` python — «неприменимо», не провал.
enum CheckOutcome: Equatable {
    case pass
    case fail(String)
    case notApplicable(String)
}

enum CheckSeverity: Equatable {
    /// Ломает контракт ответа — редьюсер обязан завершить пайплайн FAIL сразу.
    case hard
    /// Содержательное расхождение — влияет на вердикт мягче (не хуже UNSURE).
    case warning
}

struct ConfidenceCheck: Equatable {
    let name: String
    let outcome: CheckOutcome
    let severity: CheckSeverity
}

enum ConfidenceChecks {
    private static let minTaskSimilarity = 0.5

    /// Для чата: эталона нет, проверяем внутреннюю согласованность с транскриптом.
    static func referenceFree(raw: String, transcript: String) -> [ConfidenceCheck] {
        // Порядок как в python run_checks(): «валидный JSON» перед «без прозы».
        var checks: [ConfidenceCheck] = []
        let items = ActionItemsParser.parse(raw)
        checks.append(.init(name: "валидный JSON",
                             outcome: items != nil ? .pass
                                : .fail("ответ не разобран как объект {action_items: [...]}"),
                             severity: .hard))
        checks.append(.init(name: "без прозы", outcome: cleanOutcome(raw), severity: .hard))

        guard let items else {
            checks.append(.init(name: "срок из транскрипта",
                                 outcome: .notApplicable("неприменимо: JSON не разобран"), severity: .warning))
            checks.append(.init(name: "ответственный из транскрипта",
                                 outcome: .notApplicable("неприменимо: JSON не разобран"), severity: .warning))
            return checks
        }

        guard !items.isEmpty else {
            checks.append(.init(name: "срок из транскрипта",
                                 outcome: .notApplicable("неприменимо: поручений нет"), severity: .warning))
            checks.append(.init(name: "ответственный из транскрипта",
                                 outcome: .notApplicable("неприменимо: поручений нет"), severity: .warning))
            return checks
        }

        let transcriptNorm = ActionItemsParser.normalize(transcript)
        let invalidDue = items.filter { item in
            guard let due = item.due, !due.isEmpty else { return false }
            return !transcriptNorm.contains(ActionItemsParser.normalize(due))
        }.count
        checks.append(.init(name: "срок из транскрипта",
                             outcome: invalidDue == 0 ? .pass : .fail("сроков не из транскрипта: \(invalidDue)"),
                             severity: .warning))

        let invalidAssignee = items.filter { item in
            guard let assignee = item.assignee, !assignee.isEmpty else { return false }
            return !transcriptNorm.contains(ActionItemsParser.normalize(assignee))
        }.count
        checks.append(.init(name: "ответственный из транскрипта",
                             outcome: invalidAssignee == 0 ? .pass
                                : .fail("ответственных не из транскрипта: \(invalidAssignee)"),
                             severity: .warning))
        return checks
    }

    /// Порт `run_checks()`: все 9 проверок, включая «неприменимо» на месте `ok=None`.
    static func referenceBased(raw: String, reference: String, transcript: String) -> [ConfidenceCheck] {
        var checks: [ConfidenceCheck] = []
        let modelRaw = ActionItemsParser.parseTopLevel(raw)

        checks.append(.init(name: "валидный JSON",
                             outcome: modelRaw != nil ? .pass
                                : .fail("ответ не разобран как объект {action_items: [...]}"),
                             severity: .hard))
        checks.append(.init(name: "без прозы", outcome: cleanOutcome(raw), severity: .hard))

        guard let model = modelRaw else {
            for name in ["схема элементов", "число поручений", "ничего не выдумано", "ничего не упущено",
                         "ответственные совпадают", "срок не выдуман", "формулировка задачи"] {
                checks.append(.init(name: name, outcome: .notApplicable("неприменимо: JSON не разобран"),
                                     severity: .warning))
            }
            return checks
        }

        let expectedRaw = ActionItemsParser.parseTopLevel(reference) ?? []
        let (validModel, badCount) = ActionItemsParser.validateItems(model)
        checks.append(.init(name: "схема элементов",
                             outcome: badCount == 0 ? .pass
                                : .fail("элементов с нарушенной схемой: \(badCount)"),
                             severity: .hard))

        let sameCount = model.count == expectedRaw.count
        checks.append(.init(name: "число поручений",
                             outcome: sameCount ? .pass : .fail("\(model.count) вместо \(expectedRaw.count)"),
                             severity: .warning))

        let expectedEmpty = expectedRaw.isEmpty
        if !expectedEmpty {
            checks.append(.init(name: "ничего не выдумано",
                                 outcome: .notApplicable("неприменимо: во фрагменте есть поручения"),
                                 severity: .warning))
            let found = !model.isEmpty
            checks.append(.init(name: "ничего не упущено",
                                 outcome: found ? .pass : .fail("модель вернула пустой список"),
                                 severity: .warning))
        } else {
            let empty = model.isEmpty
            checks.append(.init(name: "ничего не выдумано",
                                 outcome: empty ? .pass : .fail("выдумано поручений: \(model.count)"),
                                 severity: .warning))
            checks.append(.init(name: "ничего не упущено",
                                 outcome: .notApplicable("неприменимо: во фрагменте нет поручений"),
                                 severity: .warning))
        }

        guard !expectedEmpty else {
            for name in ["ответственные совпадают", "срок не выдуман", "формулировка задачи"] {
                checks.append(.init(name: name,
                                     outcome: .notApplicable("неприменимо: во фрагменте нет поручений"),
                                     severity: .warning))
            }
            return checks
        }

        guard badCount == 0 else {
            for name in ["ответственные совпадают", "срок не выдуман", "формулировка задачи"] {
                checks.append(.init(name: name,
                                     outcome: .notApplicable("неприменимо: схема элементов нарушена"),
                                     severity: .warning))
            }
            return checks
        }

        // Reference доверенный (наш valid.jsonl) — при нарушенной схеме элементы просто
        // выпадают из подсчёта, а не роняют проверку исключением, как сделал бы python.
        let (validExpected, _) = ActionItemsParser.validateItems(expectedRaw)

        let modelNames = countedNames(validModel)
        let expectedNames = countedNames(validExpected)
        let namesMatch = modelNames == expectedNames
        checks.append(.init(name: "ответственные совпадают",
                             outcome: namesMatch ? .pass
                                : .fail("\(sortedDescription(modelNames)) вместо \(sortedDescription(expectedNames))"),
                             severity: .warning))

        let modelDueCount = validModel.filter { !($0.due ?? "").isEmpty }.count
        let expectedDueCount = validExpected.filter { !($0.due ?? "").isEmpty }.count
        let invented = modelDueCount - expectedDueCount
        checks.append(.init(name: "срок не выдуман",
                             outcome: invented <= 0 ? .pass : .fail("сроков больше эталона на \(invented)"),
                             severity: .warning))

        let modelTasks = validModel.map { ActionItemsParser.normalize($0.task) }.sorted().joined(separator: " ")
        let expectedTasks = validExpected.map { ActionItemsParser.normalize($0.task) }.sorted().joined(separator: " ")
        let similarity = TextSimilarity.ratio(modelTasks, expectedTasks)
        checks.append(.init(name: "формулировка задачи",
                             outcome: similarity >= minTaskSimilarity ? .pass
                                : .fail(String(format: "похожесть %.2f (порог %.2f)", similarity, minTaskSimilarity)),
                             severity: .warning))
        return checks
    }

    private static func cleanOutcome(_ raw: String) -> CheckOutcome {
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = stripped.hasPrefix("{") && stripped.hasSuffix("}") && !stripped.contains("```")
        return clean ? .pass : .fail("вокруг JSON есть текст или ```-обёртка")
    }

    private static func countedNames(_ items: [ActionItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items { counts[ActionItemsParser.normalize(item.assignee), default: 0] += 1 }
        return counts
    }

    private static func sortedDescription(_ names: [String: Int]) -> String {
        names.keys.sorted().description
    }
}
