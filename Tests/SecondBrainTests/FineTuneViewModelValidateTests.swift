// FineTuneViewModelValidateTests.swift — задача 82: FineTuneViewModel.validate(dataset:).
//
// status < 0 (нет python, таймаут) — ошибка уровня приложения, не результат проверки
// датасета: кладётся в validationErrorText (свой на validate(), отдельно от общего
// errorText start()/stopCurrent()/installBest() — ревью задачи 82), но НЕ пишется в
// FineTuneStore — иначе временный сбой затирал бы последний настоящий результат
// валидации, показанный пользователю без повторного запуска. Реальный Process не
// запускается — CLIRunner инжектирован.

import XCTest
@testable import SecondBrain

@MainActor
final class FineTuneViewModelValidateTests: XCTestCase {
    var tempDir: URL!
    var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-FineTuneVMValidate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("finetune-runs.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDataset() -> FineTuneDataset {
        FineTuneDataset(id: ".", title: "finetune", workdir: ".", rootURL: tempDir,
                        dataURL: tempDir.appendingPathComponent("data"),
                        trainCount: 10, validCount: 2, split: nil, systemPromptPath: nil)
    }

    func testInfrastructureFailureSetsErrorTextWithoutTouchingStore() async {
        let store = FineTuneStore(url: storeURL)
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { _ in
            .init(status: -1, output: "не удалось запустить validate.py: нет python")
        }, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })

        await viewModel.validate(dataset: makeDataset())

        XCTAssertEqual(viewModel.validationErrorText, "не удалось запустить validate.py: нет python")
        XCTAssertNil(store.validationRecord(workdir: "."), "инфраструктурный сбой не создаёт запись результата")
    }

    /// Ключевой сценарий регрессии: настоящий результат валидации уже есть в сторе —
    /// последующий инфраструктурный сбой (например, таймаут) не должен его затирать.
    func testInfrastructureFailureAfterRealResultDoesNotOverwriteIt() async {
        let store = FineTuneStore(url: storeURL)
        let previous = FineTuneValidationRecord(isValid: true, notes: ["OK"], issues: [])
        store.setValidation(previous, workdir: ".")

        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { _ in
            .init(status: -1, output: "validate.py не завершился за 15 с и был остановлен.")
        }, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })

        await viewModel.validate(dataset: makeDataset())

        XCTAssertEqual(viewModel.validationErrorText, "validate.py не завершился за 15 с и был остановлен.")
        XCTAssertEqual(store.validationRecord(workdir: "."), previous,
                       "последний настоящий результат валидации не должен затираться сбоем инфраструктуры")
    }

    /// Задача 84: середина цепочки «переключатель → argv». Края покрыты отдельно
    /// (`FineTuneStoreTests` — значения, `FineTuneRunnerValidateTests` — флаги), а
    /// склейка живёт здесь, и именно она была дефектом первого круга ревью: закрыть
    /// один порог из двух — оставить валидацию классификационного датасета красной.
    func testClassificationToggleSendsBothRelaxedThresholds() async {
        let store = FineTuneStore(url: storeURL)
        var captured: [String] = []
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { arguments in
            captured = arguments
            return .init(status: 0, output: "", stdout: "OK — датасет валиден", stderr: "")
        }, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })

        await viewModel.validate(dataset: makeDataset())
        XCTAssertEqual(captured, expectedArguments(minAssistant: FineTuneStore.defaultMinAssistant,
                                                   maxReuse: FineTuneStore.defaultMaxReuse),
                       "выключено — оба порога дефолтные")

        store.setAllowsRepeatedAnswers(true, workdir: ".")
        await viewModel.validate(dataset: makeDataset())
        XCTAssertEqual(captured, expectedArguments(minAssistant: FineTuneStore.classificationMinAssistant,
                                                   maxReuse: FineTuneStore.classificationMaxReuse),
                       "включено — опущены оба порога, а не один")
    }

    private func expectedArguments(minAssistant: Int, maxReuse: Int) -> [String] {
        let data = tempDir.appendingPathComponent("data")
        return [data.appendingPathComponent("train.jsonl").path,
                data.appendingPathComponent("valid.jsonl").path,
                "--min-assistant", String(minAssistant),
                "--max-reuse", String(maxReuse)]
    }

    func testSuccessfulValidationClearsErrorTextAndStoresParsedResult() async {
        let store = FineTuneStore(url: storeURL)
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { _ in
            .init(status: 0, output: "", stdout: "OK — датасет валиден", stderr: "")
        }, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })

        await viewModel.validate(dataset: makeDataset())

        XCTAssertNil(viewModel.validationErrorText)
        XCTAssertEqual(store.validationRecord(workdir: ".")?.isValid, true)
    }

    /// Провал разбора (код 1, ошибки в stderr) — записывается в стор как невалидный
    /// результат, а не как validationErrorText: это результат проверки датасета, не сбой приложения.
    func testValidationFailureIsStoredAsResultNotErrorText() async {
        let store = FineTuneStore(url: storeURL)
        let runner = FineTuneRunner(fineTuneRoot: tempDir, validateCLI: { _ in
            .init(status: 1, output: "", stdout: "",
                  stderr: "ОШИБКИ (1):\n  data/train.jsonl:7: assistant 45 символов, допустимо 120–6000")
        }, registry: BackgroundProcessRegistry())
        let viewModel = FineTuneViewModel(store: store, runner: runner, fineTuneRoot: { nil })

        await viewModel.validate(dataset: makeDataset())

        XCTAssertNil(viewModel.validationErrorText, "невалидный датасет — не ошибка приложения")
        let record = store.validationRecord(workdir: ".")
        XCTAssertEqual(record?.isValid, false)
        XCTAssertEqual(record?.issues.first?.line, 7)
    }
}
