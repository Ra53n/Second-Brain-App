// TuneSelectionTests.swift — чистое ядро (P1) мульти-модельных тюнов одного датасета
// (задача 92): таблицы случаев без I/O.
//
// Покрыто: adapterDirName (слаг из id модели, санитизация "/", пустая/пробельная строка,
// двойной/висящий слэш, кириллица/эмодзи в id); adapterDir (префикс "adapters/");
// selectTunedRun (нет прогонов, чужой workdir, чужая база, несколько finished одной базы —
// последний по startedAt, running/failed/stopped/interrupted не берутся); chatBaseModels
// (только дефолты, дедуп с дефолтами, стабильный порядок появления, фильтр по workdir и
// статусу); legacyAdapterFallback (нет записей + 7B → true, нет записей + 3B → false,
// finished запись есть у ЭТОГО workdir → false, finished запись есть у ДРУГОГО workdir —
// не считается, легаси всё ещё уместен).

import XCTest
@testable import SecondBrain

final class TuneSelectionTests: XCTestCase {

    // MARK: - adapterDirName / adapterDir

    func testAdapterDirNameTableOfCases() {
        let cases: [(String, String, String)] = [
            ("обычный id с namespace", "mlx-community/Qwen2.5-3B-Instruct-4bit", "Qwen2.5-3B-Instruct-4bit"),
            ("без слэша", "Qwen2.5-7B-Instruct-4bit", "Qwen2.5-7B-Instruct-4bit"),
            ("пустая строка", "", "default"),
            ("только пробелы", "   ", "default"),
            ("двойной слэш", "a//b", "b"),
            ("висящий слэш в конце", "a/b/", "b"),
            ("висящий слэш в начале", "/b", "b"),
            ("несколько уровней namespace", "org/team/model-x", "model-x"),
            ("кириллица в id", "локальная/Модель-7B", "Модель-7B"),
            ("эмодзи в id", "mlx-community/Qwen🔥3B", "Qwen🔥3B"),
            ("один слэш", "/", "default"),
            ("только слэши", "///", "default"),
            ("точка", ".", "default"),
            ("двойная точка (path traversal)", "..", "default"),
            ("несколько уровней из точек (path traversal)", "../..", "default"),
            ("слэш в пробелах", " / ", "default"),
        ]
        for (name, model, expected) in cases {
            XCTAssertEqual(TuneSelection.adapterDirName(model: model), expected, name)
        }
    }

    func testAdapterDirPrefixesWithAdaptersFolder() {
        XCTAssertEqual(TuneSelection.adapterDir(model: "mlx-community/Qwen2.5-3B-Instruct-4bit"),
                       "adapters/Qwen2.5-3B-Instruct-4bit")
        XCTAssertEqual(TuneSelection.adapterDir(model: ""), "adapters/default")
        // Path traversal ("adapters/..") резолвился бы в корень датасета, куда
        // train.py не должен писать чекпоинты — санитизация обязана дать "default".
        XCTAssertEqual(TuneSelection.adapterDir(model: ".."), "adapters/default")
        XCTAssertEqual(TuneSelection.adapterDir(model: "../.."), "adapters/default")
        XCTAssertEqual(TuneSelection.adapterDir(model: "/"), "adapters/default")
    }

    // MARK: - selectTunedRun

    private func makeRun(workdir: String, model: String, status: FineTuneRun.Status,
                         startedAt: Date = Date()) -> FineTuneRun {
        var run = FineTuneRun(workdir: workdir, datasetTitle: workdir, model: model,
                              hyperparameters: FineTuneHyperparameters(), logPath: "runs/train.log",
                              adapterPath: TuneSelection.adapterDir(model: model))
        run.status = status
        run.startedAt = startedAt
        return run
    }

    func testSelectTunedRunNoRunsReturnsNil() {
        XCTAssertNil(TuneSelection.selectTunedRun(runs: [], workdir: "dictation", baseModel: "7B"))
    }

    func testSelectTunedRunIgnoresOtherWorkdir() {
        let run = makeRun(workdir: "meetings", model: "7B", status: .finished)
        XCTAssertNil(TuneSelection.selectTunedRun(runs: [run], workdir: "dictation", baseModel: "7B"))
    }

    func testSelectTunedRunIgnoresOtherBase() {
        let run = makeRun(workdir: "dictation", model: "3B", status: .finished)
        XCTAssertNil(TuneSelection.selectTunedRun(runs: [run], workdir: "dictation", baseModel: "7B"))
    }

    func testSelectTunedRunPicksLatestFinishedOfSameWorkdirAndBase() {
        let older = makeRun(workdir: "dictation", model: "7B", status: .finished,
                            startedAt: Date(timeIntervalSince1970: 1000))
        let newer = makeRun(workdir: "dictation", model: "7B", status: .finished,
                            startedAt: Date(timeIntervalSince1970: 2000))
        let unrelated = makeRun(workdir: "dictation", model: "3B", status: .finished,
                                startedAt: Date(timeIntervalSince1970: 3000))
        let selected = TuneSelection.selectTunedRun(runs: [older, newer, unrelated],
                                                     workdir: "dictation", baseModel: "7B")
        XCTAssertEqual(selected?.id, newer.id, "последний по startedAt среди finished этой базы")
    }

    func testSelectTunedRunSkipsNonFinishedStatuses() {
        let statuses: [(String, FineTuneRun.Status)] = [
            ("running", .running), ("failed", .failed), ("stopped", .stopped), ("interrupted", .interrupted),
        ]
        for (name, status) in statuses {
            let run = makeRun(workdir: "dictation", model: "7B", status: status)
            XCTAssertNil(TuneSelection.selectTunedRun(runs: [run], workdir: "dictation", baseModel: "7B"), name)
        }
    }

    // MARK: - chatBaseModels

    func testChatBaseModelsWithoutRunsReturnsOnlyDefaultsInOrder() {
        let result = TuneSelection.chatBaseModels(runs: [], workdir: "dictation", defaults: ["3B", "7B"])
        XCTAssertEqual(result, ["3B", "7B"])
    }

    func testChatBaseModelsDeduplicatesAgainstDefaults() {
        let run = makeRun(workdir: "dictation", model: "7B", status: .finished)
        let result = TuneSelection.chatBaseModels(runs: [run], workdir: "dictation", defaults: ["3B", "7B"])
        XCTAssertEqual(result, ["3B", "7B"], "модель прогона совпадает с дефолтом — без дубля")
    }

    func testChatBaseModelsAppendsDistinctFinishedModelsInEncounterOrder() {
        let first = makeRun(workdir: "dictation", model: "custom-A", status: .finished)
        let second = makeRun(workdir: "dictation", model: "custom-B", status: .finished)
        let dup = makeRun(workdir: "dictation", model: "custom-A", status: .finished)
        let result = TuneSelection.chatBaseModels(runs: [first, second, dup], workdir: "dictation",
                                                   defaults: ["3B", "7B"])
        XCTAssertEqual(result, ["3B", "7B", "custom-A", "custom-B"],
                       "дефолты первыми, затем distinct-модели в порядке появления, без повторов")
    }

    func testChatBaseModelsIgnoresOtherWorkdirAndNonFinishedStatus() {
        let otherWorkdir = makeRun(workdir: "meetings", model: "custom-C", status: .finished)
        let notFinished = makeRun(workdir: "dictation", model: "custom-D", status: .running)
        let result = TuneSelection.chatBaseModels(runs: [otherWorkdir, notFinished], workdir: "dictation",
                                                   defaults: ["3B", "7B"])
        XCTAssertEqual(result, ["3B", "7B"])
    }

    // MARK: - legacyAdapterFallback

    func testLegacyAdapterFallbackTrueWhenNoRecordsAndDefaultBase() {
        XCTAssertTrue(TuneSelection.legacyAdapterFallback(runs: [], workdir: "dictation",
                                                           baseModel: MlxServerConfig.defaultModel))
    }

    func testLegacyAdapterFallbackFalseWhenNoRecordsButSmallBase() {
        XCTAssertFalse(TuneSelection.legacyAdapterFallback(runs: [], workdir: "dictation",
                                                            baseModel: FineTuneViewModel.smallModel))
    }

    func testLegacyAdapterFallbackFalseWhenAnyFinishedRecordExistsForWorkdir() {
        // Finished-запись ДРУГОЙ базы (3B) уже достаточна, чтобы запретить легаси-путь под 7B —
        // молчаливая подмена чужим адаптером хуже явной ошибки tunedRunMissing.
        let run = makeRun(workdir: "dictation", model: FineTuneViewModel.smallModel, status: .finished)
        XCTAssertFalse(TuneSelection.legacyAdapterFallback(runs: [run], workdir: "dictation",
                                                            baseModel: MlxServerConfig.defaultModel))
    }

    func testLegacyAdapterFallbackIgnoresFinishedRecordsOfOtherWorkdir() {
        let run = makeRun(workdir: "meetings", model: MlxServerConfig.defaultModel, status: .finished)
        XCTAssertTrue(TuneSelection.legacyAdapterFallback(runs: [run], workdir: "dictation",
                                                           baseModel: MlxServerConfig.defaultModel),
                     "finished-запись другого workdir не запрещает легаси-путь этого")
    }

    func testLegacyAdapterFallbackIgnoresNonFinishedRecordsOfSameWorkdir() {
        let run = makeRun(workdir: "dictation", model: FineTuneViewModel.smallModel, status: .running)
        XCTAssertTrue(TuneSelection.legacyAdapterFallback(runs: [run], workdir: "dictation",
                                                           baseModel: MlxServerConfig.defaultModel),
                     "идущий (не finished) прогон не считается — легаси всё ещё уместен")
    }
}
