// TuningChatViewModelTests.swift — мини-чат тюнинга (задача 85, P5): guard тюна/baseline,
// adapterMissing на `.tuned` без адаптера, успешный send добавляет 2 сообщения и
// персистит, clearChat во время генерации не роняет и не воскрешает поздний ответ.
// Задача 89: независимость тредов по варианту — история/конфиг/статистика не текут
// между baseline и tuned, переключение варианта возвращает всё без потерь.

import XCTest
@testable import SecondBrain

private final class MockManagedProcess: ManagedProcess {
    private(set) var running = true
    var isRunning: Bool { running }
    func sendTerminationSignal() { running = false }
    func sendKillSignal() { running = false }
}

@MainActor
final class TuningChatViewModelTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Сервер, у которого спавн/health всегда успешны — реальный Process не запускается.
    /// Health отслеживает `isRunning` спавненного мока (не голый bool-флаг): задача 89
    /// переключает варианты внутри одного теста, и после `stopNow()` (смена конфига)
    /// порт обязан снова выглядеть свободным для следующего `ensureRunning`.
    private func makeReadyServer() -> MlxServerManager {
        var process: MockManagedProcess?
        return MlxServerManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in let p = MockManagedProcess(); process = p; return p },
            health: { _ in process?.isRunning ?? false },
            pythonResolver: { URL(fileURLWithPath: "/fake/python3") },
            healthRetryDelay: 0)
    }

    private func makeDataset(withTunedAdapter: Bool = false) -> FineTuneDataset {
        let root = tempDir.appendingPathComponent("meetings")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("data"),
                                                  withIntermediateDirectories: true)
        if withTunedAdapter {
            let adaptersDir = root.appendingPathComponent("adapters")
            try? FileManager.default.createDirectory(at: adaptersDir, withIntermediateDirectories: true)
            try? Data().write(to: adaptersDir.appendingPathComponent("adapters.safetensors"))
        }
        return FineTuneDataset(id: "meetings", title: "Встречи", workdir: "meetings", rootURL: root,
                               dataURL: root.appendingPathComponent("data"), trainCount: 0, validCount: 0,
                               split: nil, systemPromptPath: nil)
    }

    private func tempFileURL() -> URL {
        tempDir.appendingPathComponent("finetune-chat-\(UUID().uuidString).json")
    }

    func testSendGuardsWhenTuneOrBaselineActive() async {
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { self.makeDataset() },
            isTuneOrBaselineActive: { true },
            fileURL: tempFileURL())
        vm.input = "привет"
        await vm.send()
        XCTAssertEqual(vm.errorText, FineTuneError.tuneActive.errorDescription)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    func testSendGuardsMissingAdapterForTunedVariant() async {
        let dataset = makeDataset(withTunedAdapter: false)
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.modelVariant = .tuned
        vm.input = "привет"
        await vm.send()
        XCTAssertEqual(vm.errorText, FineTuneError.adapterMissing.errorDescription)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    func testSuccessfulSendAppendsTwoMessagesAndPersists() async {
        let dataset = makeDataset()
        let fileURL = tempFileURL()
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: fileURL)
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, "user")
        XCTAssertEqual(vm.messages[1].role, "assistant")
        XCTAssertNotNil(vm.messages[1].report)
        XCTAssertFalse(vm.isGenerating)
        XCTAssertNil(vm.errorText)

        let persisted = TuningChatPersistence.load(from: fileURL)
        XCTAssertEqual(persisted.threads[FineTuneModelVariant.baseline.rawValue]?.messages.count, 2)
    }

    /// Дефолт задачи 86 — только constraint: `send()` без явного включения тумблеров
    /// делает ровно один сетевой вызов, не пять.
    func testSendWithDefaultPipelineConfigMakesOnlyOneCall() async {
        let dataset = makeDataset()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in provider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.input = "фрагмент встречи"
        await vm.send()
        XCTAssertEqual(provider.receivedMessages.count, 1)
        XCTAssertNotNil(vm.sessionStats)
        XCTAssertEqual(vm.sessionStats?.needingReinference, 0)
    }

    /// `setPipelineConfig` меняет то, что применится к следующему сообщению, и переживает
    /// перезапуск (персист через `persistNow`).
    func testSetPipelineConfigPersistsAndAppliesToNextSend() async {
        let dataset = makeDataset()
        let fileURL = tempFileURL()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in provider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: fileURL)
        vm.setPipelineConfig(.allEnabled)

        XCTAssertEqual(TuningChatPersistence.load(from: fileURL).threads[FineTuneModelVariant.baseline.rawValue]?.pipelineConfig,
                       .allEnabled)

        vm.input = "фрагмент встречи"
        await vm.send()
        XCTAssertEqual(provider.receivedMessages.count, 5, "новый конфиг применился к следующему сообщению")
    }

    func testSendWithEmptyInputIsNoOp() async {
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { self.makeDataset() },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.input = "   \n  "
        await vm.send()
        XCTAssertTrue(vm.messages.isEmpty, "пустой/пробельный ввод не отправляется")
        XCTAssertFalse(vm.isGenerating)
    }

    /// `dataset() == nil` — каталог «Встречи» просто не найден/не просканирован, не
    /// «репозиторий не задан» (`.noRepoRoot` вводит в заблуждение — репозиторий может
    /// быть настроен, а сообщение звучит наоборот).
    func testSendWithoutDatasetShowsDatasetNotFoundError() async {
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { nil },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.input = "фрагмент"
        await vm.send()
        XCTAssertEqual(vm.errorText, FineTuneError.datasetNotFound.errorDescription)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    func testRunBatchWithoutDatasetShowsDatasetNotFoundError() async {
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { nil },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        await vm.runBatch(variant: .baseline)
        XCTAssertEqual(vm.batchErrorText, FineTuneError.datasetNotFound.errorDescription)
        XCTAssertNil(vm.lastBatchReportURL)
    }

    /// Повторный `send()` во время уже идущей генерации — гейт `isGenerating`
    /// обязан сделать его no-op, а не поставить в очередь второй сетевой вызов.
    func testSendDuringGenerationIsNoOpSecondCall() async {
        let dataset = makeDataset()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        provider.delay = 0.15
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in provider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.pipelineConfig = .allEnabled // дефолт задачи 86 — только constraint, тесту нужен полный прогон
        vm.input = "первое сообщение"

        let firstSend = Task { await vm.send() }
        try? await Task.sleep(nanoseconds: 50_000_000) // первый send() уже в isGenerating
        XCTAssertTrue(vm.isGenerating)
        vm.input = "второе сообщение"
        await vm.send() // гейт: должен вернуться немедленно, не начиная второй прогон
        await firstSend.value

        // Один успешный send() — 1 основной + 2 redundancy + scoring + self-check = 5
        // сетевых вызовов (redundancyCount=3 по умолчанию, см. ConfidencePipeline);
        // второй send() поверх идущей генерации не добавил ни одного.
        XCTAssertEqual(provider.receivedMessages.count, 5, "второй send() не сделал ни одного сетевого вызова")
        XCTAssertEqual(vm.messages.count, 2, "только пара сообщений от первого send()")
        XCTAssertEqual(vm.messages[0].content, "первое сообщение")
    }

    /// `runBatch` во время идущего `send()` делит тот же гейт `isGenerating` (осознанное
    /// решение задачи — «второй одновременный батч/отправка исключены общим гейтом»).
    func testRunBatchDuringSendIsNoOp() async {
        let dataset = makeDataset()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        provider.delay = 0.15
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in provider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.input = "сообщение"

        let sendTask = Task { await vm.send() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(vm.isGenerating)
        await vm.runBatch(variant: .baseline)
        await sendTask.value

        XCTAssertNil(vm.batchErrorText, "гейт — тихий no-op, не ошибка")
        XCTAssertNil(vm.lastBatchReportURL, "батч не запускался во время send()")
    }

    func testClearChatDuringGenerationDoesNotResurrectLateAnswer() async {
        let dataset = makeDataset()
        let fileURL = tempFileURL()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        provider.delay = 0.2
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in provider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: fileURL)
        vm.input = "фрагмент встречи"

        let task = Task { await vm.send() }
        try? await Task.sleep(nanoseconds: 50_000_000) // дать send() уйти в ожидание сети
        vm.clearChat()
        await task.value

        XCTAssertTrue(vm.messages.isEmpty, "clearChat инвалидировал прогон — поздний ответ не возвращается")
    }

    /// `clearChat()` обязан не только скрыть результат (`chatGen`-гейт), но и реально
    /// прервать сеть — иначе до 5 фоновых вызовов пайплайна (основной + 2 redundancy +
    /// scoring + self-check) доезжают вхолостую, продлевая жизнь mlx-сервера markUsed'ом.
    func testClearChatCancelsInFlightPipelineAndNoFurtherCallsArrive() async throws {
        let dataset = makeDataset()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        provider.delay = 0.2 // Task.sleep внутри мока реагирует на отмену почти мгновенно
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in provider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.pipelineConfig = .allEnabled // без redundancy/scoring/self-check тест был бы бессодержательным
        vm.input = "фрагмент встречи"

        let task = Task { await vm.send() }
        try? await Task.sleep(nanoseconds: 50_000_000) // дать send() дойти до первого сетевого вызова
        vm.clearChat()
        await task.value

        let callsRightAfterCancel = provider.receivedMessages.count
        XCTAssertEqual(callsRightAfterCancel, 1, "только основной вызов успел уйти до отмены")

        // Если бы clearChat() отменял только по chatGen (не по Task), redundancy/scoring/
        // self-check всё равно доехали бы за оставшееся время — ждём дольше суммарной
        // длительности всех 5 вызовов и проверяем, что новых нет.
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(provider.receivedMessages.count, callsRightAfterCancel,
                       "после clearChat() ни один следующий вызов пайплайна не должен прийти")
    }

    // Задача 90: `lastReport` — отчёт последнего ассистентского сообщения активного треда.
    func testLastReportReturnsLatestAssistantReportOrNil() async {
        let dataset = makeDataset()
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        XCTAssertNil(vm.lastReport, "пустой тред — отчёта нет")

        vm.input = "первый фрагмент"
        await vm.send()
        let first = vm.lastReport
        XCTAssertNotNil(first)

        // «Последний, а не первый»: засеваем два ответа с разными вердиктами напрямую.
        let okReport = ConfidenceReport(verdict: .ok, reasons: [], metrics: ConfidenceMetrics(
            totalCalls: 1, extraCalls: 0, primaryLatency: 1, totalLatency: 1,
            promptTokens: 1, completionTokens: 1), checks: [])
        let failReport = ConfidenceReport(verdict: .fail, reasons: ["причина"], metrics: ConfidenceMetrics(
            totalCalls: 1, extraCalls: 0, primaryLatency: 1, totalLatency: 1,
            promptTokens: 1, completionTokens: 1), checks: [])
        vm.messages = [
            TuningChatMessage(role: "assistant", content: "первый", report: okReport),
            TuningChatMessage(role: "user", content: "вопрос"),
            TuningChatMessage(role: "assistant", content: "второй", report: failReport)
        ]
        XCTAssertEqual(vm.lastReport?.verdict, .fail, "lastReport — отчёт именно последнего ответа")
        // Переключение варианта меняет тред — у пустого треда отчёта нет.
        vm.modelVariant = .tuned
        XCTAssertNil(vm.lastReport)
    }

    // Задача 89 (ревью, P5): программная смена варианта во время генерации не должна
    // уронить ответ в чужой тред — прогон отменяется, как при clearChat().
    func testSwitchingVariantDuringGenerationCancelsAndKeepsThreadsClean() async throws {
        let dataset = makeDataset(withTunedAdapter: true)
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        provider.delay = 0.2
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in provider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.input = "фрагмент встречи"

        let task = Task { await vm.send() }
        try? await Task.sleep(nanoseconds: 50_000_000) // основной вызов в полёте
        vm.modelVariant = .tuned
        await task.value

        XCTAssertFalse(vm.isGenerating, "смена варианта отменяет прогон")
        XCTAssertTrue(vm.messages.isEmpty, "tuned-тред пуст — ответ baseline в него не упал")
        XCTAssertEqual(vm.threads[FineTuneModelVariant.tuned.rawValue]?.messages.count ?? 0, 0)
        // Ответ не дописался и в baseline-тред: прогон отменён до завершения.
        let baselineMessages = vm.threads[FineTuneModelVariant.baseline.rawValue]?.messages ?? []
        XCTAssertEqual(baselineMessages.filter { $0.role == "assistant" }.count, 0)
    }

    // Задача 87: кнопка «Очистить чат» доступна и во время батча — отменённый прогон
    // обязан сбросить batchProgress/batchErrorText (иначе счётчик «N/M» замерзает:
    // гейт `gen == chatGen` в catch после бампа поколения сам их не сбросит).
    func testClearChatDuringBatchResetsBatchProgressAndPersistsEmpty() async throws {
        let dataset = makeDataset()
        let provider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        provider.delay = 0.2
        let fileURL = tempFileURL()
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in provider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: fileURL)

        // makeDataset() не пишет valid.jsonl — без него runBatch падает мгновенно
        // (datasetUnreadable) и прогресс сбрасывается раньше первой проверки.
        let line = #"{"messages":[{"role":"system","content":"s"},{"role":"user","content":"фрагмент"},{"role":"assistant","content":"{\"action_items\": []}"}]}"#
        try Data(line.utf8).write(to: dataset.dataURL.appendingPathComponent("valid.jsonl"))

        let task = Task { await vm.runBatch(variant: .baseline) }
        try? await Task.sleep(nanoseconds: 50_000_000) // батч дошёл до первого вызова
        XCTAssertNotNil(vm.batchProgress, "прогон стартовал — прогресс виден")
        vm.clearChat()
        await task.value

        XCTAssertNil(vm.batchProgress, "clearChat() во время батча сбрасывает счётчик прогресса")
        XCTAssertNil(vm.batchErrorText)
        XCTAssertFalse(vm.isGenerating)
        // Критерий 2 задачи 87 проверяем в данных (дешевле и надёжнее UI): после
        // очистки на диске персистится пустая история.
        let document = TuningChatPersistence.load(from: fileURL)
        XCTAssertTrue(document.threads[FineTuneModelVariant.baseline.rawValue]?.messages.isEmpty ?? true,
                      "после очистки finetune-chat.json хранит пустую историю активного треда")
    }

    // MARK: - Задача 89: раздельные треды по варианту

    /// `send()` в baseline-треде не должен трогать tuned-тред — независимость на диске.
    func testSendInBaselineDoesNotTouchTunedThreadOnDisk() async {
        let dataset = makeDataset()
        let fileURL = tempFileURL()
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: fileURL)
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertEqual(vm.messages.count, 2)
        let persisted = TuningChatPersistence.load(from: fileURL)
        XCTAssertTrue(persisted.threads[FineTuneModelVariant.tuned.rawValue]?.messages.isEmpty ?? true,
                      "tuned-тред не тронут отправкой в baseline")
    }

    /// Переключение варианта меняет `messages`/`pipelineConfig` на свои для варианта и
    /// возвращает всё без потерь при переключении обратно.
    func testSwitchingVariantSwapsProjectionsWithoutLoss() async {
        let dataset = makeDataset(withTunedAdapter: true)
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.input = "фрагмент из baseline"
        await vm.send()
        XCTAssertEqual(vm.messages.count, 2)
        let baselineMessages = vm.messages

        vm.modelVariant = .tuned
        XCTAssertTrue(vm.messages.isEmpty, "у tuned свежий тред — история baseline не видна")
        XCTAssertEqual(vm.pipelineConfig, .default)

        vm.setPipelineConfig(.allEnabled)
        vm.input = "фрагмент из тюна"
        await vm.send()
        XCTAssertEqual(vm.messages.count, 2)
        let tunedMessages = vm.messages

        vm.modelVariant = .baseline
        XCTAssertEqual(vm.messages.map(\.content), baselineMessages.map(\.content),
                       "возврат в baseline восстанавливает его историю без потерь")
        XCTAssertEqual(vm.pipelineConfig, .default, "baseline-конфиг не тронут переключением тюна")

        vm.modelVariant = .tuned
        XCTAssertEqual(vm.messages.map(\.content), tunedMessages.map(\.content),
                       "возврат в tuned восстанавливает его историю без потерь")
        XCTAssertEqual(vm.pipelineConfig, .allEnabled, "tuned-конфиг пережил переключение туда-обратно")
    }

    /// `clearChat()` чистит только активный тред — второй остаётся целым и в памяти, и на диске.
    func testClearChatClearsOnlyActiveThreadSecondThreadIntact() async {
        let dataset = makeDataset(withTunedAdapter: true)
        let fileURL = tempFileURL()
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: fileURL)
        vm.input = "фрагмент из baseline"
        await vm.send()
        XCTAssertEqual(vm.messages.count, 2)

        vm.modelVariant = .tuned
        vm.input = "фрагмент из тюна"
        await vm.send()
        XCTAssertEqual(vm.messages.count, 2)

        vm.clearChat()
        XCTAssertTrue(vm.messages.isEmpty, "активный (tuned) тред очищен")

        vm.modelVariant = .baseline
        XCTAssertEqual(vm.messages.count, 2, "baseline-тред цел в памяти")

        let persisted = TuningChatPersistence.load(from: fileURL)
        XCTAssertEqual(persisted.threads[FineTuneModelVariant.baseline.rawValue]?.messages.count, 2,
                       "baseline-тред цел на диске")
        XCTAssertTrue(persisted.threads[FineTuneModelVariant.tuned.rawValue]?.messages.isEmpty ?? true,
                      "tuned-тред очищен на диске")
    }

    /// `setPipelineConfig()` пишет только в тред активного варианта.
    func testSetPipelineConfigWritesOnlyActiveThread() {
        let fileURL = tempFileURL()
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: ["{\"action_items\":[]}"]) },
            dataset: { self.makeDataset() },
            isTuneOrBaselineActive: { false },
            fileURL: fileURL)

        vm.setPipelineConfig(.allEnabled)
        XCTAssertEqual(vm.pipelineConfig, .allEnabled)

        vm.modelVariant = .tuned
        XCTAssertEqual(vm.pipelineConfig, .default, "tuned-тред не тронут setPipelineConfig в baseline")

        let persisted = TuningChatPersistence.load(from: fileURL)
        XCTAssertEqual(persisted.threads[FineTuneModelVariant.baseline.rawValue]?.pipelineConfig, .allEnabled)
    }
}
