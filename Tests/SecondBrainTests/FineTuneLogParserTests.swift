// FineTuneLogParserTests.swift — задача 81: строка лога mlx-lm → точка прогресса.
//
// Дословные строки реального прогона (val перед train — обе начинаются "Iter N:"),
// служебные строки без точки, tqdm-мусор через \r, "значение из будущего".

import XCTest
@testable import SecondBrain

final class FineTuneLogParserTests: XCTestCase {

    // MARK: - Реальные строки лога

    /// Регрессия на смену версии mlx-lm: строки ниже сняты с живого прогона на
    /// mlx-lm 0.31.3 (образцы выше — с прогона на 0.28.4). Формат совпал, но
    /// поймать его расхождение должен тест, а не пользователь с пустым графиком.
    /// Здесь же появилась строка «Saved final weights to …» — без «Iter N:»,
    /// точкой прогресса быть не должна.
    func testРеальныйЛогНовойВерсииMlxLmРазбираетсяЦеликом() {
        let log = """
        Loading pretrained model
        Loading datasets
        Training
        Trainable parameters: 0.019% (1.442M/7615.617M)
        Starting training..., iters: 2
        Iter 1: Val loss 2.788, Val took 1.620s
        Iter 1: Saved adapter weights to /x/_smoketune/adapters/adapters.safetensors and \
        /x/_smoketune/adapters/0000001_adapters.safetensors.
        Iter 2: Val loss 2.186, Val took 3.335s
        Iter 2: Train loss 2.712, Learning Rate 1.000e-05, It/sec 2.212, Tokens/sec 105.290, \
        Trained Tokens 476, Peak mem 5.143 GB
        Iter 2: Saved adapter weights to /x/_smoketune/adapters/adapters.safetensors and \
        /x/_smoketune/adapters/0000002_adapters.safetensors.
        Saved final weights to /x/_smoketune/adapters/adapters.safetensors.
        """
        let points = FineTuneLogParser.points(in: log)
        XCTAssertEqual(points.count, 3, "две val-точки и одна train-точка, остальное — не точки")
        XCTAssertEqual(points.map(\.kind), [.val, .val, .train])
        XCTAssertEqual(points.map(\.iter), [1, 2, 2])
        XCTAssertEqual(points[1].loss, 2.186, accuracy: 1e-9)
        XCTAssertEqual(points[2].peakMemGB ?? 0, 5.143, accuracy: 1e-9)
        XCTAssertEqual(points[2].itPerSec ?? 0, 2.212, accuracy: 1e-9)

        // На этой кривой лучший — последний замер: переобучения ещё нет.
        let pick = FineTuneCheckpointPicker.best(from: points)
        XCTAssertEqual(pick?.iter, 2)
        XCTAssertEqual(pick?.fileName, "0000002_adapters.safetensors")
        XCTAssertEqual(pick?.isOverfit, false)
    }

    func testValLineParsesAsValKind() {
        let point = FineTuneLogParser.parse(line: "Iter 1: Val loss 2.137, Val took 15.818s")
        XCTAssertEqual(point?.iter, 1)
        XCTAssertEqual(point?.kind, .val)
        XCTAssertEqual(point?.loss ?? 0, 2.137, accuracy: 1e-9)
        XCTAssertNil(point?.itPerSec, "val-строка не несёт it/sec")
        XCTAssertNil(point?.peakMemGB, "в этой val-строке нет Peak mem")
    }

    func testTrainLineParsesAsTrainKindWithItPerSecAndPeakMem() {
        let line = "Iter 10: Train loss 2.053, Learning Rate 1.000e-05, It/sec 0.088, " +
            "Tokens/sec 73.839, Trained Tokens 8356, Peak mem 11.110 GB"
        let point = FineTuneLogParser.parse(line: line)
        XCTAssertEqual(point?.iter, 10)
        XCTAssertEqual(point?.kind, .train)
        XCTAssertEqual(point?.loss ?? 0, 2.053, accuracy: 1e-9)
        XCTAssertEqual(point?.itPerSec ?? 0, 0.088, accuracy: 1e-9)
        XCTAssertEqual(point?.peakMemGB ?? 0, 11.110, accuracy: 1e-9)
    }

    /// Обе строки начинаются "Iter N:" — val должен быть проверен раньше train,
    /// иначе "Val loss" ошибочно уедет в более широкий train-шаблон.
    func testValLineIsNotMisparsedAsTrain() {
        let point = FineTuneLogParser.parse(line: "Iter 50: Val loss 1.212, Val took 19.194s")
        XCTAssertEqual(point?.kind, .val, "val-строка не должна попасть в train-шаблон")
        XCTAssertEqual(point?.iter, 50)
        XCTAssertEqual(point?.loss ?? 0, 1.212, accuracy: 1e-9)
    }

    func testSecondTrainLineOnSameIterAsVal() {
        let line = "Iter 50: Train loss 1.046, Learning Rate 1.000e-05, It/sec 0.114, " +
            "Tokens/sec 66.357, Trained Tokens 33663, Peak mem 11.110 GB"
        let point = FineTuneLogParser.parse(line: line)
        XCTAssertEqual(point?.kind, .train)
        XCTAssertEqual(point?.iter, 50)
        XCTAssertEqual(point?.loss ?? 0, 1.046, accuracy: 1e-9)
        XCTAssertEqual(point?.itPerSec ?? 0, 0.114, accuracy: 1e-9)
    }

    /// "Saved adapter weights" — не точка прогресса, даже когда начинается "Iter N:".
    func testSavedAdapterWeightsLineIsNotAPoint() {
        let line = "Iter 50: Saved adapter weights to /x/adapters/adapters.safetensors " +
            "and /x/adapters/0000050_adapters.safetensors."
        XCTAssertNil(FineTuneLogParser.parse(line: line))
    }

    // MARK: - Служебные строки без "Iter"

    func testServiceLinesWithoutIterAreNil() {
        for line in [
            "Loading pretrained model",
            "Training",
            "Starting training..., iters: 300",
            "Trainable parameters: 0.076% (5.767M/7615.617M)"
        ] {
            XCTAssertNil(FineTuneLogParser.parse(line: line), line)
        }
    }

    func testEmptyAndGarbageLinesAreNil() {
        for line in ["", "   ", "мусор без структуры", "🚀🚀🚀", "Iter: Val loss"] {
            XCTAssertNil(FineTuneLogParser.parse(line: line), line)
        }
    }

    func testCaseInsensitiveMatching() {
        let point = FineTuneLogParser.parse(line: "iter 1: VAL LOSS 2.137, val took 15.818s")
        XCTAssertEqual(point?.kind, .val)
        XCTAssertEqual(point?.iter, 1)
    }

    /// «Значение из будущего»: итерация больше сконфигурированного лимита прогона
    /// разбирается штатно — обрезает прогресс сам потребитель, не парсер.
    func testFutureIterationParsesNormally() {
        let point = FineTuneLogParser.parse(line: "Iter 999999: Val loss 0.1")
        XCTAssertEqual(point?.iter, 999999)
        XCTAssertEqual(point?.kind, .val)
        XCTAssertEqual(point?.loss ?? 0, 0.1, accuracy: 1e-9)
    }

    // MARK: - points(in:) — резка по \n и \r

    func testPointsFromFullRealLog() {
        let log = """
        Iter 1: Val loss 2.137, Val took 15.818s
        Iter 10: Train loss 2.053, Learning Rate 1.000e-05, It/sec 0.088, Tokens/sec 73.839, Trained Tokens 8356, Peak mem 11.110 GB
        Iter 50: Val loss 1.212, Val took 19.194s
        Iter 50: Train loss 1.046, Learning Rate 1.000e-05, It/sec 0.114, Tokens/sec 66.357, Trained Tokens 33663, Peak mem 11.110 GB
        Iter 50: Saved adapter weights to /x/adapters/adapters.safetensors and /x/adapters/0000050_adapters.safetensors.
        """
        let points = FineTuneLogParser.points(in: log)
        XCTAssertEqual(points.count, 4, "Saved adapter weights — не точка")
        XCTAssertEqual(points.map(\.kind), [.val, .train, .val, .train])
        XCTAssertEqual(points.map(\.iter), [1, 10, 50, 50])
    }

    /// tqdm пишет прогрессбар через \r в ту же физическую строку — резка обязана
    /// учитывать и \r, иначе прогрессбар и реальная Iter-строка склеятся в одну.
    func testSplitsOnCarriageReturnNotOnlyNewline() {
        let text = "Calculating loss...:  25%|██▌       | 1/4 [00:02<00:07,  2.55s/it]" +
            "\rIter 1: Val loss 2.137, Val took 15.818s"
        let points = FineTuneLogParser.points(in: text)
        XCTAssertEqual(points.count, 1, "Iter-строка должна разобраться, даже слепленная \\r с прогрессбаром")
        XCTAssertEqual(points.first?.iter, 1)
        XCTAssertEqual(points.first?.kind, .val)
    }

    func testEmptyTextProducesNoPoints() {
        XCTAssertEqual(FineTuneLogParser.points(in: ""), [])
    }

    // MARK: - displayLines

    func testDisplayLinesDropsTqdmGarbage() {
        let text = "Calculating loss...:  25%|██▌       | 1/4 [00:02<00:07,  2.55s/it]\n" +
            "Iter 1: Val loss 2.137, Val took 15.818s\n" +
            "training: 100%|██████████| 4/4 [00:09<00:00,  2.3s/it]\n"
        let lines = FineTuneLogParser.displayLines(in: text, limit: 10)
        XCTAssertEqual(lines, ["Iter 1: Val loss 2.137, Val took 15.818s"],
                       "tqdm-прогрессбары (%|, it/s]) не идут в отображаемый хвост")
    }

    /// Прогрессбар и реальная строка, слепленные \r в одну физическую строку без \n:
    /// без резки по \r вся строка целиком содержит "%|" и была бы отброшена целиком,
    /// унеся с собой настоящий Iter.
    func testDisplayLinesSeparatesCarriageReturnJoinedProgressFromRealLine() {
        let text = "Calculating loss...:  25%|██▌       | 1/4 [00:02<00:07,  2.55s/it]" +
            "\rIter 1: Val loss 2.137, Val took 15.818s"
        let lines = FineTuneLogParser.displayLines(in: text, limit: 10)
        XCTAssertEqual(lines, ["Iter 1: Val loss 2.137, Val took 15.818s"])
    }

    func testDisplayLinesRespectsLimit() {
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let lines = FineTuneLogParser.displayLines(in: text, limit: 2)
        XCTAssertEqual(lines, ["line 4", "line 5"], "только последние `limit` строк")
    }

    func testDisplayLinesLimitZeroIsEmpty() {
        let lines = FineTuneLogParser.displayLines(in: "a\nb\nc", limit: 0)
        XCTAssertEqual(lines, [])
    }

    func testDisplayLinesDropsConsecutiveDuplicatesAndEmpties() {
        let text = "a\na\n\n   \nb\nb\nb\nc"
        let lines = FineTuneLogParser.displayLines(in: text, limit: 10)
        XCTAssertEqual(lines, ["a", "b", "c"])
    }

    func testDisplayLinesEmptyInput() {
        XCTAssertEqual(FineTuneLogParser.displayLines(in: "", limit: 10), [])
    }
}
