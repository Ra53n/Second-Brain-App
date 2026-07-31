// FineTunePipelineStatusTests.swift — задача 83: статус пайплайна вкладки «Обзор».
//
// Чистое ядро без I/O — таблицы случаев по каждому шагу (dataset/validation/
// baseline/criteria/training/comparison), плюс стабильность порядка шагов.
// Ревью 83: последний прогон .failed — .attention, не .done.

import XCTest
@testable import SecondBrain

final class FineTunePipelineStatusTests: XCTestCase {
    private func baseInput(trainCount: Int = 10, validCount: Int = 3,
                           validation: FineTuneValidationRecord? = nil,
                           hasBaseline: Bool = false, hasCriteria: Bool = false,
                           hasTunedSnapshot: Bool = false,
                           runs: [FineTuneRun] = []) -> FineTunePipelineStatus.Input {
        FineTunePipelineStatus.Input(trainCount: trainCount, validCount: validCount,
                                     validation: validation, hasBaseline: hasBaseline,
                                     hasCriteria: hasCriteria, hasTunedSnapshot: hasTunedSnapshot, runs: runs)
    }

    private func run(status: FineTuneRun.Status = .finished, iter: Int? = nil) -> FineTuneRun {
        var run = FineTuneRun(workdir: ".", datasetTitle: "d", model: "m",
                              hyperparameters: FineTuneHyperparameters(iters: 300),
                              logPath: "train.log", adapterPath: "adapters")
        run.status = status
        if let iter {
            run.points = [FineTuneProgressPoint(iter: iter, kind: .train, loss: 1, itPerSec: nil, peakMemGB: nil)]
        }
        return run
    }

    private func step(_ steps: [FineTunePipelineStatus.Step], _ id: FineTunePipelineStatus.StepID)
        -> FineTunePipelineStatus.Step {
        steps.first { $0.id == id }!
    }

    // MARK: - dataset

    func testDatasetStepDoneWithCountsWhenEvalPresent() {
        let steps = FineTunePipelineStatus.steps(baseInput(trainCount: 10, validCount: 3))
        XCTAssertEqual(step(steps, .dataset).state, .done("10 train / 3 valid"))
        XCTAssertNil(step(steps, .dataset).action)
    }

    func testDatasetStepAttentionWhenNoEvalExamples() {
        let steps = FineTunePipelineStatus.steps(baseInput(trainCount: 10, validCount: 0))
        XCTAssertEqual(step(steps, .dataset).state, .attention("нет eval-примеров"))
    }

    // MARK: - validation

    func testValidationStepMissingWhenNeverChecked() {
        let steps = FineTunePipelineStatus.steps(baseInput(validation: nil))
        XCTAssertEqual(step(steps, .validation).state, .missing("датасет не проверялся"))
        XCTAssertEqual(step(steps, .validation).action, .validate)
    }

    func testValidationStepDoneWhenValid() {
        let record = FineTuneValidationRecord(isValid: true, notes: [], issues: [])
        let steps = FineTunePipelineStatus.steps(baseInput(validation: record))
        guard case .done(let detail) = step(steps, .validation).state else {
            return XCTFail("ожидался .done")
        }
        XCTAssertTrue(detail.hasPrefix("OK ·"), detail)
        XCTAssertEqual(step(steps, .validation).action, .openTab(.examples))
    }

    func testValidationStepAttentionWithIssueCountWhenInvalid() {
        let issues = (1...4).map { FineTuneValidationRecord.Issue(file: "train.jsonl", line: $0, text: "ошибка") }
        let record = FineTuneValidationRecord(isValid: false, notes: [], issues: issues)
        let steps = FineTunePipelineStatus.steps(baseInput(validation: record))
        XCTAssertEqual(step(steps, .validation).state, .attention("4 ошибок"))
        XCTAssertEqual(step(steps, .validation).action, .openTab(.examples))
    }

    // MARK: - baseline / criteria

    func testBaselineStepReflectsPresence() {
        for hasBaseline in [true, false] {
            let steps = FineTunePipelineStatus.steps(baseInput(hasBaseline: hasBaseline))
            let result = step(steps, .baseline)
            if hasBaseline {
                XCTAssertEqual(result.state, .done("ответы сняты"))
                XCTAssertEqual(result.action, .openTab(.baseline))
            } else {
                XCTAssertEqual(result.state, .missing("baseline не снят"))
                XCTAssertEqual(result.action, .snapshotBaseline)
            }
        }
    }

    func testCriteriaStepReflectsPresence() {
        for hasCriteria in [true, false] {
            let steps = FineTunePipelineStatus.steps(baseInput(hasCriteria: hasCriteria))
            let result = step(steps, .criteria)
            if hasCriteria {
                XCTAssertEqual(result.state, .done("criteria.md есть"))
                XCTAssertEqual(result.action, .openTab(.criteria))
            } else {
                XCTAssertEqual(result.state, .missing("критериев нет"))
                XCTAssertEqual(result.action, .generateCriteria)
            }
        }
    }

    // MARK: - training

    func testTrainingStepMissingWithoutRuns() {
        let steps = FineTunePipelineStatus.steps(baseInput(runs: []))
        XCTAssertEqual(step(steps, .training).state, .missing("прогонов не было"))
        XCTAssertEqual(step(steps, .training).action, .openTab(.runs))
    }

    func testTrainingStepAttentionWhileRunning() {
        let steps = FineTunePipelineStatus.steps(baseInput(runs: [run(status: .running, iter: 120)]))
        XCTAssertEqual(step(steps, .training).state, .attention("идёт: iter 120/300"))
        XCTAssertEqual(step(steps, .training).action, .openTab(.runs))
    }

    func testTrainingStepDoneWithCountAndLastStatusWhenFinished() {
        let steps = FineTunePipelineStatus.steps(baseInput(runs: [run(status: .finished), run(status: .failed)]))
        XCTAssertEqual(step(steps, .training).state, .done("2 прогонов, последний — завершён"))
    }

    func testTrainingStepUsesRussianLabelPerStatus() {
        let cases: [(FineTuneRun.Status, String)] = [
            (.finished, "завершён"), (.stopped, "остановлен"), (.interrupted, "прерван")
        ]
        for (status, label) in cases {
            let steps = FineTunePipelineStatus.steps(baseInput(runs: [run(status: status)]))
            XCTAssertEqual(step(steps, .training).state, .done("1 прогонов, последний — \(label)"), "\(status)")
        }
    }

    /// Ревью задачи 83: последний прогон .failed — это не «всё готово», кнопка
    /// «Обучение» должна привлекать внимание, а не выглядеть done.
    func testTrainingStepAttentionWhenLastRunFailed() {
        let steps = FineTunePipelineStatus.steps(baseInput(runs: [run(status: .failed), run(status: .finished)]))
        XCTAssertEqual(step(steps, .training).state, .attention("2 прогонов, последний — провалился"))
    }

    // MARK: - comparison

    func testComparisonStepReflectsTunedSnapshotWithoutAction() {
        for hasTuned in [true, false] {
            let steps = FineTunePipelineStatus.steps(baseInput(hasTunedSnapshot: hasTuned))
            let result = step(steps, .comparison)
            XCTAssertNil(result.action)
            if hasTuned {
                XCTAssertEqual(result.state, .done("ответы тюна сняты"))
            } else {
                XCTAssertEqual(result.state, .missing("снимите ответы тюна: baseline.py --adapter"))
            }
        }
    }

    // MARK: - порядок шагов

    func testStepsOrderIsStable() {
        let steps = FineTunePipelineStatus.steps(baseInput())
        XCTAssertEqual(steps.map(\.id), [.dataset, .validation, .baseline, .criteria, .training, .comparison])
    }
}
