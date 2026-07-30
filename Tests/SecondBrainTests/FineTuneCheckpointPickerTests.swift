// FineTuneCheckpointPickerTests.swift — задача 81: выбор чекпоинта по минимуму val loss.
//
// Реальная кривая замеренного прогона (val loss достигает минимума на 50-й итерации
// из 300 и дальше растёт — переобучение), ничья по loss → более ранняя итерация,
// монотонное убывание → последняя точка, train-точки не участвуют.

import XCTest
@testable import SecondBrain

final class FineTuneCheckpointPickerTests: XCTestCase {

    private func valPoint(_ iter: Int, _ loss: Double) -> FineTuneProgressPoint {
        FineTuneProgressPoint(iter: iter, kind: .val, loss: loss, itPerSec: nil, peakMemGB: nil)
    }

    private func trainPoint(_ iter: Int, _ loss: Double) -> FineTuneProgressPoint {
        FineTuneProgressPoint(iter: iter, kind: .train, loss: loss, itPerSec: 0.1, peakMemGB: nil)
    }

    /// Замеренный прогон задачи 81: минимум на 50-й итерации, дальше рост — переобучение.
    func testMeasuredRunPicksIter50AsOverfit() {
        let points = [valPoint(1, 2.137), valPoint(50, 1.212), valPoint(100, 1.753), valPoint(150, 1.473)]
        let pick = FineTuneCheckpointPicker.best(from: points)
        XCTAssertEqual(pick?.iter, 50)
        XCTAssertEqual(pick?.valLoss ?? 0, 1.212, accuracy: 1e-9)
        XCTAssertEqual(pick?.lastValLoss ?? 0, 1.473, accuracy: 1e-9)
        XCTAssertEqual(pick?.isOverfit, true, "финальный val loss (1.473) выше минимума (1.212)")
        XCTAssertEqual(pick?.fileName, "0000050_adapters.safetensors")
    }

    /// Равные val loss на двух итерациях — выигрывает более ранняя (как min() в python-CLI).
    func testTieBreaksToEarlierIteration() {
        let points = [valPoint(50, 1.0), valPoint(100, 1.0)]
        let pick = FineTuneCheckpointPicker.best(from: points)
        XCTAssertEqual(pick?.iter, 50, "ничья по loss — раньше означает меньше переобучения")
        XCTAssertEqual(pick?.isOverfit, false, "последняя точка равна лучшей — не переобучение")
    }

    /// Три точки с одинаковым loss в перемешанном (не по iter) порядке — best()
    /// сортирует вход сам, поэтому порядок на входе не сбивает более раннюю.
    func testTieAmongThreeEqualPointsPicksEarliestRegardlessOfInputOrder() {
        let points = [valPoint(100, 0.9), valPoint(10, 0.9), valPoint(50, 0.9)]
        let pick = FineTuneCheckpointPicker.best(from: points)
        XCTAssertEqual(pick?.iter, 10)
    }

    func testMonotonicallyDecreasingCurvePicksLastPoint() {
        let points = [valPoint(1, 2.0), valPoint(50, 1.5), valPoint(100, 1.0)]
        let pick = FineTuneCheckpointPicker.best(from: points)
        XCTAssertEqual(pick?.iter, 100)
        XCTAssertEqual(pick?.isOverfit, false)
    }

    func testTrainPointsAreIgnored() {
        let points = [trainPoint(1, 0.01), valPoint(50, 1.212), trainPoint(100, 0.001)]
        let pick = FineTuneCheckpointPicker.best(from: points)
        XCTAssertEqual(pick?.iter, 50, "train loss (много меньше) не должен побеждать val")
    }

    func testSinglePointIsBestAndNotOverfit() {
        let pick = FineTuneCheckpointPicker.best(from: [valPoint(1, 2.137)])
        XCTAssertEqual(pick?.iter, 1)
        XCTAssertEqual(pick?.valLoss ?? 0, 2.137, accuracy: 1e-9)
        XCTAssertEqual(pick?.lastValLoss ?? 0, 2.137, accuracy: 1e-9)
        XCTAssertEqual(pick?.isOverfit, false)
    }

    func testEmptyInputIsNil() {
        XCTAssertNil(FineTuneCheckpointPicker.best(from: []))
    }

    func testOnlyTrainPointsIsNil() {
        XCTAssertNil(FineTuneCheckpointPicker.best(from: [trainPoint(1, 0.5), trainPoint(2, 0.4)]),
                     "без единой val-точки чекпоинт выбрать нечем")
    }
}
