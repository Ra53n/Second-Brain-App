// FineTunePipelineStatus.swift — статус пайплайна тюнинга для вкладки «Обзор» (задача 83).
//
// Чистое ядро (P1): факты о датасете на диске → список шагов с человекочитаемым
// статусом и действием. Ноль I/O — входные данные собирает вызывающий (ViewModel/View).

import Foundation

enum FineTunePipelineStatus {
    /// Факты о датасете, нужные для статуса шагов.
    struct Input: Equatable {
        var trainCount: Int
        var validCount: Int
        var validation: FineTuneValidationRecord?
        var hasBaseline: Bool
        var hasCriteria: Bool
        var hasTunedSnapshot: Bool
        var runs: [FineTuneRun]
    }

    /// Шаг пайплайна, в порядке отображения.
    enum StepID: CaseIterable {
        case dataset, validation, baseline, criteria, training, comparison

        var title: String {
            switch self {
            case .dataset: return "Датасет"
            case .validation: return "Валидация"
            case .baseline: return "Baseline"
            case .criteria: return "Критерии"
            case .training: return "Обучение"
            case .comparison: return "Сравнение"
            }
        }
    }

    /// Строка — человекочитаемая деталь для UI (число, дата, статус словами).
    enum StepState: Equatable {
        case done(String)
        case attention(String)
        case missing(String)
    }

    /// Что делает кнопка действия шага. snapshotBaseline/generateCriteria ведут на
    /// соответствующую вкладку — там же кнопка запуска с подтверждением перезаписи.
    enum StepAction: Equatable {
        case openTab(FineTuneDatasetTab)
        case validate
        case snapshotBaseline
        case generateCriteria
    }

    struct Step: Equatable, Identifiable {
        let id: StepID
        let state: StepState
        let action: StepAction?
    }

    static func steps(_ input: Input) -> [Step] {
        StepID.allCases.map { id in
            switch id {
            case .dataset: return datasetStep(input)
            case .validation: return validationStep(input)
            case .baseline: return baselineStep(input)
            case .criteria: return criteriaStep(input)
            case .training: return trainingStep(input)
            case .comparison: return comparisonStep(input)
            }
        }
    }

    private static func datasetStep(_ input: Input) -> Step {
        let detail = "\(input.trainCount) train / \(input.validCount) valid"
        let state: StepState = input.validCount == 0 ? .attention("нет eval-примеров") : .done(detail)
        return Step(id: .dataset, state: state, action: nil)
    }

    private static func validationStep(_ input: Input) -> Step {
        guard let validation = input.validation else {
            return Step(id: .validation, state: .missing("датасет не проверялся"), action: .validate)
        }
        if validation.isValid {
            let date = validation.checkedAt.formatted(date: .abbreviated, time: .omitted)
            return Step(id: .validation, state: .done("OK · \(date)"), action: .openTab(.examples))
        }
        let count = validation.issues.count
        return Step(id: .validation, state: .attention("\(count) ошибок"), action: .openTab(.examples))
    }

    private static func baselineStep(_ input: Input) -> Step {
        input.hasBaseline
            ? Step(id: .baseline, state: .done("ответы сняты"), action: .openTab(.baseline))
            : Step(id: .baseline, state: .missing("baseline не снят"), action: .snapshotBaseline)
    }

    private static func criteriaStep(_ input: Input) -> Step {
        input.hasCriteria
            ? Step(id: .criteria, state: .done("criteria.md есть"), action: .openTab(.criteria))
            : Step(id: .criteria, state: .missing("критериев нет"), action: .generateCriteria)
    }

    private static func trainingStep(_ input: Input) -> Step {
        if let running = input.runs.first(where: { $0.status == .running }) {
            let iter = running.points.last?.iter ?? 0
            let detail = "идёт: iter \(iter)/\(running.hyperparameters.iters)"
            return Step(id: .training, state: .attention(detail), action: .openTab(.runs))
        }
        guard let last = input.runs.first else {
            return Step(id: .training, state: .missing("прогонов не было"), action: .openTab(.runs))
        }
        let detail = "\(input.runs.count) прогонов, последний — \(statusLabel(last.status))"
        let state: StepState = last.status == .failed ? .attention(detail) : .done(detail)
        return Step(id: .training, state: state, action: .openTab(.runs))
    }

    private static func comparisonStep(_ input: Input) -> Step {
        input.hasTunedSnapshot
            ? Step(id: .comparison, state: .done("ответы тюна сняты"), action: nil)
            : Step(id: .comparison, state: .missing("снимите ответы тюна: baseline.py --adapter"), action: nil)
    }

    private static func statusLabel(_ status: FineTuneRun.Status) -> String {
        switch status {
        case .running: return "выполняется"
        case .finished: return "завершён"
        case .stopped: return "остановлен"
        case .interrupted: return "прерван"
        case .failed: return "провалился"
        }
    }
}
