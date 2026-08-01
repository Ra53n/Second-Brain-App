// FineTuneStoreTests.swift — задача 81: персистентность finetune-runs.json (P2).
//
// Round-trip через persistNow()/второй стор, карантин битого файла, миграция
// минимального JSON, безопасный дефолт незнакомого статуса, кап истории,
// normalize() зависшего running с мёртвым pid.
//
// Задача 82 дополняет: миграция без validations/minAssistantOverrides, round-trip
// обоих новых полей, регрессия «appendRun не должен стирать их на диске», дефолт
// min-assistant по наличию system_prompt.txt, makeDocument — общая точка сборки
// документа для persistNow() и дебаунс-автосохранения (ревью: раньше эти пути могли
// разойтись по набору полей).
//
// Задача 83 дополняет: миграция без baselineCountOverrides, round-trip через
// setBaselineCount, makeDocument — четвёртое поле.
//
// Задача 84 дополняет: миграция без maxReuseOverrides, round-trip через setMaxReuse,
// переключатель «датасет классификации» ↔ оба порога валидатора, makeDocument — пятое поле.

import XCTest
@testable import SecondBrain

@MainActor
final class FineTuneStoreTests: XCTestCase {
    var tempDir: URL!
    var url: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-FineTune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        url = tempDir.appendingPathComponent("finetune-runs.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> FineTuneStore {
        FineTuneStore(url: url)
    }

    private func makeRun(model: String = "mlx-community/Qwen2.5-7B-Instruct-4bit") -> FineTuneRun {
        FineTuneRun(workdir: ".", datasetTitle: "finetune", model: model,
                   hyperparameters: FineTuneHyperparameters(), logPath: "runs/train.log",
                   adapterPath: "adapters")
    }

    /// Гарантированно мёртвый pid: дожидаемся завершения дочернего процесса и
    /// переиспользуем его pid — он уже пожат нами, повторно им никто не пользуется
    /// за время теста.
    private func deadPid() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    // MARK: - Round-trip

    func testRoundTripThroughPersistNowAndSecondStore() {
        var run = makeRun()
        run.points = [FineTuneProgressPoint(iter: 1, kind: .val, loss: 2.137, itPerSec: nil, peakMemGB: nil)]
        run.bestIter = 1
        run.status = .finished
        run.finishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        run.isAdoptedExternally = true

        let store = makeStore()
        store.appendRun(run)
        store.persistNow()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.runs.count, 1)
        XCTAssertEqual(reloaded.runs.first, run)
    }

    func testCorruptFileIsQuarantinedAndStoreStartsEmpty() throws {
        try Data("{ не json совсем".utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.runs, [])
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "битый файл уезжает в карантин")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Миграция

    /// Минимальный JSON старой версии — без любых полей, кроме model. Прогон не теряется.
    func testMigrationFromMinimalJSONKeepsRunWithDefaults() throws {
        try Data(#"{"runs":[{"model":"x"}]}"#.utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.runs.count, 1, "прогон не теряется при отсутствии полей")
        let run = store.runs[0]
        XCTAssertEqual(run.model, "x")
        XCTAssertEqual(run.workdir, ".")
        XCTAssertEqual(run.datasetTitle, "")
        XCTAssertEqual(run.hyperparameters, FineTuneHyperparameters())
        XCTAssertNil(run.pid)
        XCTAssertNil(run.finishedAt)
        XCTAssertEqual(run.points, [])
        XCTAssertNil(run.bestIter)
        XCTAssertEqual(run.logPath, "")
        XCTAssertEqual(run.adapterPath, "")
    }

    /// Незнакомое поле isAdoptedExternally (задача 81, доработка) — старый JSON без
    /// него грузит "свой" прогон, не "чужой".
    func testMigrationDefaultsIsAdoptedExternallyToFalse() throws {
        try Data(#"{"runs":[{"model":"x"}]}"#.utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.runs.first?.isAdoptedExternally, false)
    }

    /// Точка с незнакомым kind «из будущего» выпадает целиком — подмена вида
    /// (например на .train) исказила бы график и выбор чекпоинта.
    func testFuturePointKindIsDroppedNotDefaulted() throws {
        let json = """
        {"runs":[{"model":"x","points":[\
        {"iter":1,"kind":"val","loss":1.0},\
        {"iter":2,"kind":"forecast","loss":0.5},\
        {"iter":3,"kind":"train","loss":0.9,"itPerSec":0.1}]}]}
        """
        try Data(json.utf8).write(to: url)
        let store = makeStore()
        let points = store.runs.first?.points ?? []
        XCTAssertEqual(points.map(\.iter), [1, 3], "точка с kind:\"forecast\" выпадает, остальные целы")
    }

    /// Незнакомый статус «из будущего» — безопасный дефолт .interrupted, НЕ .running
    /// (running тянул бы за собой сигналы процессу на прогоне, который никто не запускал).
    func testUnknownFutureStatusDecodesToSafeDefault() throws {
        try Data(#"{"runs":[{"model":"x","status":"queued"}]}"#.utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.runs[0].status, .interrupted,
                       "незнакомый статус должен декодироваться в безопасный дефолт, не в .running")
    }

    // MARK: - Кап истории

    func testRunsCapEvictsOldest() {
        let store = makeStore()
        for i in 0..<(FineTuneStore.runsCap + 5) {
            var run = makeRun()
            run.datasetTitle = "run-\(i)"
            store.appendRun(run)
        }
        XCTAssertEqual(store.runs.count, FineTuneStore.runsCap)
        XCTAssertEqual(store.runs.first?.datasetTitle, "run-\(FineTuneStore.runsCap + 4)",
                       "новые — в начале")
        XCTAssertEqual(store.runs.last?.datasetTitle, "run-5", "старейшие вытеснены")
    }

    // MARK: - normalize()

    func testNormalizeInterruptsRunningWithDeadPid() throws {
        var running = makeRun()
        running.status = .running
        running.pid = deadPid()
        let document = FineTuneDocument(runs: [running])
        FineTunePersistence.save(document, to: url)

        let store = makeStore()
        let normalized = store.runs.first { $0.id == running.id }
        XCTAssertEqual(normalized?.status, .interrupted,
                       "зависший running без живого процесса — прерван при старте")
        XCTAssertNotNil(normalized?.finishedAt)

        // Нормализация зафиксирована на диске синхронно.
        let onDisk = FineTunePersistence.loadDocument(from: url)
        XCTAssertEqual(onDisk.runs.first?.status, .interrupted)
    }

    func testNormalizeLeavesRunningWithLivePidUntouched() throws {
        var running = makeRun()
        running.status = .running
        running.pid = getpid()
        let document = FineTuneDocument(runs: [running])
        FineTunePersistence.save(document, to: url)

        let store = makeStore()
        XCTAssertEqual(store.runs.first?.status, .running, "живой pid — не трогаем при старте")
    }

    /// pid 0 (недописанный run.json) — kill(0,0) отвечает 0 (группа приложения),
    /// что без guard'а выглядело бы как живой прогон навсегда.
    func testNormalizeInterruptsRunningWithPidZero() throws {
        var running = makeRun()
        running.status = .running
        running.pid = 0
        let document = FineTuneDocument(runs: [running])
        FineTunePersistence.save(document, to: url)

        let store = makeStore()
        XCTAssertEqual(store.runs.first?.status, .interrupted, "pid 0 не должен считаться живым")
    }

    func testNormalizeLeavesFinishedRunsUntouched() throws {
        var finished = makeRun()
        finished.status = .finished
        let document = FineTuneDocument(runs: [finished])
        FineTunePersistence.save(document, to: url)

        let store = makeStore()
        XCTAssertEqual(store.runs.first?.status, .finished)
    }

    // MARK: - updateRun / latestRun

    func testUpdateRunMutatesAndPersists() {
        let run = makeRun()
        let store = makeStore()
        store.appendRun(run)
        let updated = store.updateRun(id: run.id) { $0.status = .stopped }
        XCTAssertTrue(updated)
        XCTAssertEqual(store.runs.first?.status, .stopped)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.runs.first?.status, .stopped)
    }

    func testUpdateRunUnknownIDReturnsFalse() {
        let store = makeStore()
        XCTAssertFalse(store.updateRun(id: UUID()) { $0.status = .stopped })
    }

    func testLatestRunReturnsNewestForWorkdir() {
        let store = makeStore()
        var first = makeRun()
        first.workdir = "dictation"
        first.datasetTitle = "первый"
        var second = makeRun()
        second.workdir = "dictation"
        second.datasetTitle = "второй"
        store.appendRun(first)
        store.appendRun(second)
        store.appendRun(makeRun()) // workdir "." — чужой
        XCTAssertEqual(store.latestRun(workdir: "dictation")?.datasetTitle, "второй")
    }

    // MARK: - validations / minAssistantOverrides (задача 82)

    /// Документ без обоих новых полей (версия до задачи 82) — грузится с пустыми
    /// словарями, а не падает и не квалифицирует файл как битый.
    func testMigrationWithoutValidationsOrOverridesLoadsWithEmptyDefaults() throws {
        try Data(#"{"runs":[]}"#.utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.runs, [])
        XCTAssertEqual(store.validations, [:], "старый документ без этого поля — пустой словарь, не потеря")
        XCTAssertEqual(store.minAssistantOverrides, [:])
    }

    func testValidationRoundTripThroughPersistNowAndSecondStore() {
        let store = makeStore()
        let record = FineTuneValidationRecord(
            isValid: false, notes: ["note"],
            issues: [.init(file: "a.jsonl", line: 3, text: "text")],
            checkedAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.setValidation(record, workdir: "dictation")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.validationRecord(workdir: "dictation"), record)
        XCTAssertNil(reloaded.validationRecord(workdir: "."), "запись привязана к своему workdir, не глобальна")
    }

    func testMinAssistantOverrideRoundTrip() {
        let store = makeStore()
        store.setMinAssistant(42, workdir: "dictation")
        store.persistNow() // setMinAssistant не пишет синхронно — полагается на дебаунс

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.minAssistant(workdir: "dictation"), 42)
    }

    /// Регрессия (синхронный путь persistNow()/appendRun): изменение `runs` не должно
    /// затирать validations/minAssistantOverrides на диске. Дебаунс-автосохранение
    /// защищено структурно — оба пути зовут `makeDocument`, см.
    /// `testMakeDocumentCombinesAllFields`.
    func testAppendingRunDoesNotEraseValidationsOrOverridesOnDisk() {
        let store = makeStore()
        let record = FineTuneValidationRecord(isValid: true, notes: ["ok"], issues: [])
        store.setValidation(record, workdir: ".")
        store.setMinAssistant(77, workdir: ".")

        store.appendRun(makeRun())

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.runs.count, 1)
        XCTAssertEqual(reloaded.validationRecord(workdir: "."), record,
                       "новый прогон не должен стирать результат валидации на диске")
        XCTAssertEqual(reloaded.minAssistantOverrides["."], 77,
                       "новый прогон не должен стирать пользовательский порог min-assistant")
    }

    /// Дефолт `--min-assistant`: 30 у датасета со своим system_prompt.txt (диктовка —
    /// частный случай, не привязка к имени каталога), 120 у всех прочих без
    /// пользовательского переопределения.
    func testDefaultMinAssistantDependsOnOwnSystemPromptNotWorkdirName() {
        let store = makeStore()
        XCTAssertEqual(store.minAssistant(workdir: "dictation", hasOwnSystemPrompt: true), 30)
        XCTAssertEqual(store.minAssistant(workdir: "."), 120, "hasOwnSystemPrompt по умолчанию false")
        XCTAssertEqual(store.minAssistant(workdir: "some-other-dataset", hasOwnSystemPrompt: true), 30,
                       "дефолт определяется наличием system_prompt.txt, не именем workdir")
    }

    // MARK: - makeDocument (задача 82, регрессия дебаунс-подписки; задача 83 — четвёртое поле)

    /// $runs.sink раньше строил документ только из runs — с общей функцией это
    /// невозможно: и persistNow(), и дебаунс-автосохранение зовут её же.
    func testMakeDocumentCombinesAllFields() {
        let run = makeRun()
        let validations = ["a": FineTuneValidationRecord(isValid: true, notes: ["ok"], issues: [])]
        let minAssistantOverrides = ["a": 55]
        let baselineCountOverrides = ["a": 5]
        let maxReuseOverrides = ["a": 900]

        let document = FineTuneStore.makeDocument(runs: [run], validations: validations,
                                                  minAssistantOverrides: minAssistantOverrides,
                                                  baselineCountOverrides: baselineCountOverrides,
                                                  maxReuseOverrides: maxReuseOverrides)

        XCTAssertEqual(document.runs, [run])
        XCTAssertEqual(document.validations, validations)
        XCTAssertEqual(document.minAssistantOverrides, minAssistantOverrides)
        XCTAssertEqual(document.baselineCountOverrides, baselineCountOverrides)
        XCTAssertEqual(document.maxReuseOverrides, maxReuseOverrides)
    }

    // MARK: - baselineCountOverrides (задача 83)

    /// Документ без нового поля (версия до задачи 83) — грузится с пустым словарём,
    /// не падает и не квалифицирует файл как битый.
    func testMigrationWithoutBaselineCountOverridesLoadsWithEmptyDefault() throws {
        try Data(#"{"runs":[]}"#.utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.baselineCountOverrides, [:], "старый документ без этого поля — пустой словарь, не потеря")
    }

    func testSetBaselineCountPersistsAcrossStoreInstances() {
        let store = makeStore()
        store.setBaselineCount(3, workdir: "dictation")
        store.persistNow() // setBaselineCount не пишет синхронно — полагается на дебаунс

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.baselineCountOverrides["dictation"], 3)
    }

    // MARK: - maxReuseOverrides (задача 84)

    /// Документ версии до задачи 84 — грузится с пустым словарём, порог берётся
    /// дефолтный, файл не считается битым.
    func testMigrationWithoutMaxReuseOverridesLoadsWithEmptyDefault() throws {
        try Data(#"{"runs":[],"minAssistantOverrides":{"dictation":30}}"#.utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.maxReuseOverrides, [:], "старый документ без этого поля — пустой словарь, не потеря")
        XCTAssertEqual(store.maxReuse(workdir: "dictation"), FineTuneStore.defaultMaxReuse)
        XCTAssertEqual(store.minAssistantOverrides["dictation"], 30, "соседнее поле не потеряно")
    }

    /// UI задаёт порог переключателем, а не числом: осмысленного «правильного»
    /// значения нет, есть решение «повтор метки не дубль».
    func testRepeatedAnswersToggleMapsToThreshold() {
        let store = makeStore()
        XCTAssertFalse(store.allowsRepeatedAnswers(workdir: "meetings"), "по умолчанию выключено")

        store.setAllowsRepeatedAnswers(true, workdir: "meetings")
        XCTAssertEqual(store.maxReuse(workdir: "meetings"), FineTuneStore.classificationMaxReuse)
        XCTAssertTrue(store.allowsRepeatedAnswers(workdir: "meetings"))

        store.setAllowsRepeatedAnswers(false, workdir: "meetings")
        XCTAssertEqual(store.maxReuse(workdir: "meetings"), FineTuneStore.defaultMaxReuse)
        XCTAssertFalse(store.allowsRepeatedAnswers(workdir: "meetings"))
    }

    /// Оба порога валидатора ломаются об один класс датасетов, поэтому переключатель
    /// опускает их вместе: закрыть только повторы и оставить длину — оставить
    /// валидацию красной ровно так же (замечание ревью задачи 84).
    func testClassificationToggleAlsoLowersMinAssistant() {
        let store = makeStore()
        XCTAssertEqual(store.minAssistant(workdir: "meetings", hasOwnSystemPrompt: true),
                       FineTuneStore.ownSystemPromptMinAssistant)

        store.setAllowsRepeatedAnswers(true, workdir: "meetings")
        XCTAssertEqual(store.minAssistant(workdir: "meetings", hasOwnSystemPrompt: true),
                       FineTuneStore.classificationMinAssistant)
        XCTAssertEqual(store.minAssistant(workdir: "dictation", hasOwnSystemPrompt: true),
                       FineTuneStore.ownSystemPromptMinAssistant,
                       "переключатель действует на свой датасет, не на все")

        // Явная настройка пользователя сильнее переключателя: иначе Stepper переставал
        // бы работать после включения галочки.
        store.setMinAssistant(45, workdir: "meetings")
        XCTAssertEqual(store.minAssistant(workdir: "meetings", hasOwnSystemPrompt: true), 45)
    }

    func testSetMaxReusePersistsAcrossStoreInstances() {
        let store = makeStore()
        store.setMaxReuse(900, workdir: "meetings")
        store.persistNow() // setMaxReuse не пишет синхронно — полагается на дебаунс

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.maxReuse(workdir: "meetings"), 900)
        XCTAssertEqual(reloaded.maxReuse(workdir: "dictation"), FineTuneStore.defaultMaxReuse,
                       "порог задан на датасет, не на все сразу")
    }
}
