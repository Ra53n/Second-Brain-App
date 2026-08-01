// TuningChatViewModelTests.swift — мини-чат тюнинга (задача 85, P5): guard тюна/baseline,
// adapterMissing на `.tuned` без адаптера, успешный send добавляет 2 сообщения и
// персистит, clearChat во время генерации не роняет и не воскрешает поздний ответ.
// Задача 89: независимость тредов по варианту — история/конфиг/статистика не текут
// между baseline и tuned, переключение варианта возвращает всё без потерь.
// Задача 91: каскадная эскалация — succeeded/unavailable/failed через инжектированный
// escalationResolver, OK/тумблер выключен не зовёт вторую ступень, персист тумблера/цели,
// lastEscalation.
// Задача 93: цель эскалации `.localTuned` — путь VM не отличает провайдера "mlx-local" от
// облачного (резолвер уже отдал готовый ResolvedChatProvider), providerID/status
// прокидываются в EscalationRecord как есть; availableTunedModels — пусто без прогонов,
// distinct-базы finished-прогонов этого workdir (без дефолтов, в отличие от availableBaseModels).

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

    /// Ключ треда для дефолтной базы чата (задача 92, "variant|model") — VM без явного
    /// `setChatBaseModel` держит легаси-7B (`MlxServerConfig.defaultModel`).
    private func threadKey(_ variant: FineTuneModelVariant) -> String {
        "\(variant.rawValue)|\(MlxServerConfig.defaultModel)"
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
        XCTAssertEqual(persisted.threads[threadKey(.baseline)]?.messages.count, 2)
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

        XCTAssertEqual(TuningChatPersistence.load(from: fileURL).threads[threadKey(.baseline)]?.pipelineConfig,
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
        XCTAssertEqual(vm.threads[threadKey(.tuned)]?.messages.count ?? 0, 0)
        // Ответ не дописался и в baseline-тред: прогон отменён до завершения.
        let baselineMessages = vm.threads[threadKey(.baseline)]?.messages ?? []
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
        XCTAssertTrue(document.threads[threadKey(.baseline)]?.messages.isEmpty ?? true,
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
        XCTAssertTrue(persisted.threads[threadKey(.tuned)]?.messages.isEmpty ?? true,
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
        XCTAssertEqual(persisted.threads[threadKey(.baseline)]?.messages.count, 2,
                       "baseline-тред цел на диске")
        XCTAssertTrue(persisted.threads[threadKey(.tuned)]?.messages.isEmpty ?? true,
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
        XCTAssertEqual(persisted.threads[threadKey(.baseline)]?.pipelineConfig, .allEnabled)
    }

    // MARK: - Задача 91: каскадная эскалация

    /// Assignee/due вне транскрипта — мягкий constraint-провал (severity .warning),
    /// достаточный для UNSURE уже при дефолтном пайплайне (только constraint, 1 вызов).
    private let unsureResponse = #"{"action_items":[{"assignee":"Незнакомец","task":"сделать","due":"вчера"}]}"#
    private let okResponse = #"{"action_items":[]}"#

    func testSuccessfulEscalationReplacesAnswerAndReportWithStrongOneAndKeepsPrimaryReport() async throws {
        let dataset = makeDataset()
        let cheapProvider = MockChatProvider(responses: [unsureResponse])
        let strongProvider = MockChatProvider(responses: ["{\"action_items\":[]}"])
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in cheapProvider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL(),
            escalationResolver: { _ in
                .resolved(ResolvedChatProvider(provider: strongProvider, model: "strong-model",
                                                providerID: "openai", displayName: "OpenAI"))
            })
        vm.escalationEnabled = true
        vm.escalationTarget = EscalationTarget(providerID: "openai", model: "strong-model")
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertNil(vm.errorText)
        XCTAssertEqual(vm.messages.count, 2)
        let assistant = vm.messages[1]
        XCTAssertEqual(assistant.content, okResponse, "показанный ответ — сильной модели")
        XCTAssertEqual(assistant.report?.verdict, .ok, "показанный report — сильной модели")
        let escalation = try XCTUnwrap(assistant.escalation)
        XCTAssertEqual(escalation.status, .succeeded)
        XCTAssertEqual(escalation.trigger, .unsure, "trigger — вердикт дешёвой ступени")
        XCTAssertNotNil(escalation.primaryReport, "дешёвый отчёт сохранён в записи")
        XCTAssertEqual(escalation.primaryReport?.verdict, .unsure)
        XCTAssertEqual(strongProvider.receivedMessages.count, 1, "сильная модель вызвана ровно один раз")
    }

    func testUnavailableEscalationKeepsCheapAnswerWithReasonAndNoErrorText() async throws {
        let dataset = makeDataset()
        let cheapProvider = MockChatProvider(responses: [unsureResponse])
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in cheapProvider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL(),
            escalationResolver: { _ in .unavailable(reason: "модель эскалации не выбрана") })
        vm.escalationEnabled = true
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertNil(vm.errorText, "недоступность цели — P6-деградация, не ошибка")
        XCTAssertEqual(vm.messages.count, 2)
        let assistant = vm.messages[1]
        XCTAssertEqual(assistant.content, unsureResponse, "ответ дешёвой ступени сохранён")
        let escalation = try XCTUnwrap(assistant.escalation)
        XCTAssertEqual(escalation.status, .unavailable)
        XCTAssertEqual(escalation.failureReason, "модель эскалации не выбрана")
    }

    func testStrongProviderErrorMarksEscalationFailedAndKeepsCheapAnswer() async throws {
        let dataset = makeDataset()
        let cheapProvider = MockChatProvider(responses: [unsureResponse])
        let strongProvider = MockChatProvider(responses: ["{}"])
        strongProvider.errorToThrow = LLMError.providerUnavailable("openai")
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in cheapProvider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL(),
            escalationResolver: { _ in
                .resolved(ResolvedChatProvider(provider: strongProvider, model: "strong-model",
                                                providerID: "openai", displayName: "OpenAI"))
            })
        vm.escalationEnabled = true
        vm.escalationTarget = EscalationTarget(providerID: "openai", model: "strong-model")
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertNil(vm.errorText, "ошибка сильной ступени не поднимается в errorText")
        XCTAssertEqual(vm.messages.count, 2)
        let assistant = vm.messages[1]
        XCTAssertEqual(assistant.content, unsureResponse, "ответ дешёвой ступени сохранён при провале эскалации")
        let escalation = try XCTUnwrap(assistant.escalation)
        XCTAssertEqual(escalation.status, .failed)
        XCTAssertNotNil(escalation.failureReason)
    }

    /// Допущение задачи 91: отмена посреди второй ступени — `CancellationError`
    /// перебрасывается наружу, а не деградирует в `.failed`; сообщение не дописывается
    /// (симметрично `testClearChatCancelsInFlightPipelineAndNoFurtherCallsArrive`).
    func testCancellationDuringEscalationSecondStageDoesNotDegradeToFailedOrAppendMessage() async throws {
        let dataset = makeDataset()
        let cheapProvider = MockChatProvider(responses: [unsureResponse])
        let strongProvider = MockChatProvider(responses: [okResponse])
        strongProvider.delay = 0.2
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in cheapProvider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL(),
            escalationResolver: { _ in
                .resolved(ResolvedChatProvider(provider: strongProvider, model: "strong-model",
                                                providerID: "openai", displayName: "OpenAI"))
            })
        vm.escalationEnabled = true
        vm.escalationTarget = EscalationTarget(providerID: "openai", model: "strong-model")
        vm.input = "фрагмент встречи"

        let task = Task { await vm.send() }
        try? await Task.sleep(nanoseconds: 50_000_000) // дешёвый вызов завершился, сильный уже в полёте
        vm.clearChat()
        await task.value

        XCTAssertTrue(vm.messages.isEmpty, "отмена посреди эскалации — сообщение не дописывается")
        XCTAssertNil(vm.errorText, "CancellationError не деградирует в errorText/.failed")
        XCTAssertFalse(vm.isGenerating)
    }

    func testOkVerdictDoesNotEscalateEvenWithToggleOn() async throws {
        let dataset = makeDataset()
        let cheapProvider = MockChatProvider(responses: [okResponse])
        let strongProvider = MockChatProvider(responses: ["{}"])
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in cheapProvider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL(),
            escalationResolver: { _ in
                .resolved(ResolvedChatProvider(provider: strongProvider, model: "strong-model",
                                                providerID: "openai", displayName: "OpenAI"))
            })
        vm.escalationEnabled = true
        vm.escalationTarget = EscalationTarget(providerID: "openai", model: "strong-model")
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertNil(vm.messages.last?.escalation, "вердикт OK — эскалация не триггерится")
        XCTAssertEqual(strongProvider.receivedMessages.count, 0, "сильная модель не вызывалась")
    }

    func testToggleOffDoesNotEscalateEvenWithUnsureVerdict() async throws {
        let dataset = makeDataset()
        let cheapProvider = MockChatProvider(responses: [unsureResponse])
        let strongProvider = MockChatProvider(responses: ["{}"])
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in cheapProvider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL(),
            escalationResolver: { _ in
                .resolved(ResolvedChatProvider(provider: strongProvider, model: "strong-model",
                                                providerID: "openai", displayName: "OpenAI"))
            })
        vm.escalationEnabled = false
        vm.escalationTarget = EscalationTarget(providerID: "openai", model: "strong-model")
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertEqual(vm.messages.last?.report?.verdict, .unsure, "вердикт честно UNSURE")
        XCTAssertNil(vm.messages.last?.escalation, "тумблер выключен — эскалация не запускается")
        XCTAssertEqual(strongProvider.receivedMessages.count, 0, "сильная модель не вызывалась")
    }

    /// Тумблер/цель переживают перезапуск VM из того же файла; тумблер — per-thread
    /// (симметрично `pipelineConfig` задачи 89).
    func testEscalationEnabledAndTargetPersistAcrossReload() {
        let fileURL = tempFileURL()
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { self.makeDataset() },
            isTuneOrBaselineActive: { false },
            fileURL: fileURL)
        vm.setEscalationEnabled(true)
        vm.setEscalationTarget(EscalationTarget(providerID: "openai", model: "gpt-5"))

        let reloaded = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { self.makeDataset() },
            isTuneOrBaselineActive: { false },
            fileURL: fileURL)
        XCTAssertTrue(reloaded.escalationEnabled)
        XCTAssertEqual(reloaded.escalationTarget, EscalationTarget(providerID: "openai", model: "gpt-5"))
    }

    /// `escalationTarget` документный (общий на все варианты), `escalationEnabled` —
    /// тредовый: включение в baseline не должно включать его в tuned.
    func testEscalationEnabledIsPerThreadNotSharedAcrossVariants() throws {
        let dataset = makeDataset(withTunedAdapter: true)
        let fileURL = tempFileURL()
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: fileURL)
        vm.setEscalationEnabled(true)
        XCTAssertTrue(vm.escalationEnabled)

        vm.modelVariant = .tuned
        XCTAssertFalse(vm.escalationEnabled, "у tuned свой (выключенный) тумблер")

        vm.modelVariant = .baseline
        XCTAssertTrue(vm.escalationEnabled, "baseline-тумблер не тронут переключением")
    }

    /// `lastEscalation` — запись эскалации именно последнего ассистентского сообщения.
    func testLastEscalationReturnsLatestAssistantEscalationOrNil() {
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { self.makeDataset() },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        XCTAssertNil(vm.lastEscalation, "пустой тред — эскалации нет")

        let okReport = ConfidenceReport(verdict: .ok, reasons: [], metrics: ConfidenceMetrics(totalCalls: 1), checks: [])
        let firstEscalation = EscalationRecord(status: .unavailable, trigger: .unsure, failureReason: "первая причина")
        let secondEscalation = EscalationRecord(status: .succeeded, trigger: .fail, providerID: "openai",
                                                 model: "gpt-5", primaryReport: okReport)
        vm.messages = [
            TuningChatMessage(role: "assistant", content: "первый", report: okReport, escalation: firstEscalation),
            TuningChatMessage(role: "user", content: "вопрос"),
            TuningChatMessage(role: "assistant", content: "второй", report: okReport, escalation: secondEscalation),
        ]
        XCTAssertEqual(vm.lastEscalation?.status, .succeeded, "lastEscalation — запись именно последнего ответа")
    }

    // MARK: - Задача 93: локальная mlx-цель эскалации (.localTuned)

    /// VM не отличает `.localTuned` от `.registry` в рантайме — резолвер (в проде
    /// `EscalationTargetResolver` + строитель `localTune` из AppModel) уже отдал готовый
    /// `ResolvedChatProvider` с сентинел-providerID "mlx-local". Мок здесь эмулирует именно
    /// эту точку: успешная эскалация на локальную тюненую модель проходит confidence-пайплайн
    /// и providerID/model записи — "mlx-local"/база тюна.
    func testLocalTunedEscalationSucceedsWithMlxLocalProviderIDInRecord() async throws {
        let dataset = makeDataset()
        let cheapProvider = MockChatProvider(responses: [unsureResponse])
        let strongProvider = MockChatProvider(responses: [okResponse])
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in cheapProvider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL(),
            escalationResolver: { target in
                XCTAssertEqual(target?.kind, .localTuned)
                return .resolved(ResolvedChatProvider(provider: strongProvider, model: "Qwen2.5-7B-Instruct-4bit",
                                                       providerID: .localTunedProviderID, displayName: "Тюн 7B (локально)"))
            })
        vm.escalationEnabled = true
        vm.escalationTarget = EscalationTarget(providerID: .localTunedProviderID, model: "Qwen2.5-7B-Instruct-4bit", kind: .localTuned)
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertNil(vm.errorText)
        let assistant = try XCTUnwrap(vm.messages.last)
        XCTAssertEqual(assistant.content, okResponse, "показанный ответ — локальной тюненой модели")
        let escalation = try XCTUnwrap(assistant.escalation)
        XCTAssertEqual(escalation.status, .succeeded)
        XCTAssertEqual(escalation.providerID, "mlx-local")
        XCTAssertEqual(escalation.model, "Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(strongProvider.receivedMessages.count, 1)
    }

    /// Строитель `localTune` (в проде — нет finished-тюна выбранной базы) отдал
    /// `.unavailable` — дешёвый ответ сохранён, причина названа, ошибки в errorText нет.
    func testLocalTunedEscalationUnavailableKeepsCheapAnswerWithReason() async throws {
        let dataset = makeDataset()
        let cheapProvider = MockChatProvider(responses: [unsureResponse])
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in cheapProvider },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL(),
            escalationResolver: { _ in .unavailable(reason: "нет тюна базы «Qwen2.5-7B-Instruct-4bit»") })
        vm.escalationEnabled = true
        vm.escalationTarget = EscalationTarget(providerID: .localTunedProviderID, model: "Qwen2.5-7B-Instruct-4bit", kind: .localTuned)
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertNil(vm.errorText)
        let assistant = try XCTUnwrap(vm.messages.last)
        XCTAssertEqual(assistant.content, unsureResponse)
        let escalation = try XCTUnwrap(assistant.escalation)
        XCTAssertEqual(escalation.status, .unavailable)
        XCTAssertEqual(escalation.failureReason, "нет тюна базы «Qwen2.5-7B-Instruct-4bit»")
    }

    /// `availableTunedModels` — без единого finished-прогона пуст (в отличие от
    /// `availableBaseModels`, у которого всегда есть дефолты 3B/7B).
    func testAvailableTunedModelsIsEmptyWithoutFinishedRuns() {
        let dataset = makeDataset()
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { dataset },
            runs: { [] },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        XCTAssertEqual(vm.availableTunedModels, [])
    }

    /// Легаси-тюн 7B (адаптер на диске, записи в истории нет) виден как локальная цель
    /// эскалации — живой сценарий: 7B тюнился до появления истории прогонов.
    func testAvailableTunedModelsIncludesLegacySevenBWhenAdapterFileExists() {
        let dataset = makeDataset(withTunedAdapter: true)
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { dataset },
            runs: { [] },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        XCTAssertEqual(vm.availableTunedModels, [MlxServerConfig.defaultModel])
    }

    /// Finished-прогон другой базы (3B) не осиротит легаси-7B — в списке обе цели.
    func testAvailableTunedModelsKeepsLegacySevenBAfterOtherBaseFinishedRun() {
        let dataset = makeDataset(withTunedAdapter: true)
        let finished3B = makeFinishedRun(workdir: dataset.workdir, model: FineTuneViewModel.smallModel,
                                         adapterPath: "adapters/3b")
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { dataset },
            runs: { [finished3B] },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        XCTAssertEqual(vm.availableTunedModels, [FineTuneViewModel.smallModel, MlxServerConfig.defaultModel])
    }

    /// distinct-базы finished-прогонов ЭТОГО workdir, без дублей и без прогонов
    /// других датасетов/незавершённых прогонов.
    func testAvailableTunedModelsContainsDistinctFinishedRunModelsOfThisWorkdirOnly() {
        let dataset = makeDataset()
        let finishedA = makeFinishedRun(workdir: dataset.workdir, model: "Qwen2.5-7B-Instruct-4bit",
                                        adapterPath: "adapters/7b")
        let finishedADup = makeFinishedRun(workdir: dataset.workdir, model: "Qwen2.5-7B-Instruct-4bit",
                                           adapterPath: "adapters/7b-2")
        var runningB = makeFinishedRun(workdir: dataset.workdir, model: "still-running-model",
                                       adapterPath: "adapters/running")
        runningB.status = .running
        let otherWorkdirRun = makeFinishedRun(workdir: "other-dataset", model: "should-not-appear",
                                              adapterPath: "adapters/should-not-appear")
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { dataset },
            runs: { [finishedA, finishedADup, runningB, otherWorkdirRun] },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        XCTAssertEqual(vm.availableTunedModels, ["Qwen2.5-7B-Instruct-4bit"],
                       "дубль базы не повторяется, running/чужой workdir не попадают")
    }

    // MARK: - Задача 92: мульти-модельные тюны — база чата, TuneSelection

    private func makeFinishedRun(workdir: String, model: String, adapterPath: String) -> FineTuneRun {
        var run = FineTuneRun(workdir: workdir, datasetTitle: workdir, model: model,
                              hyperparameters: FineTuneHyperparameters(), logPath: "runs/train.log",
                              adapterPath: adapterPath)
        run.status = .finished
        return run
    }

    /// `setChatBaseModel` — переключение зеркально `modelVariant`: своя история на диске
    /// и в памяти для каждой базы, без потерь при возврате.
    func testSetChatBaseModelSwitchesThreadHistoryIsSeparate() async {
        let dataset = makeDataset()
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { dataset },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.input = "на 7B"
        await vm.send()
        XCTAssertEqual(vm.messages.count, 2)
        let sevenBMessages = vm.messages

        vm.setChatBaseModel(FineTuneViewModel.smallModel)
        XCTAssertTrue(vm.messages.isEmpty, "у новой базы свежий тред")

        vm.input = "на 3B"
        await vm.send()
        XCTAssertEqual(vm.messages.count, 2)
        let threeBMessages = vm.messages

        vm.setChatBaseModel(MlxServerConfig.defaultModel)
        XCTAssertEqual(vm.messages.map(\.content), sevenBMessages.map(\.content),
                       "возврат на 7B восстанавливает её историю без потерь")

        vm.setChatBaseModel(FineTuneViewModel.smallModel)
        XCTAssertEqual(vm.messages.map(\.content), threeBMessages.map(\.content),
                       "возврат на 3B восстанавливает её историю без потерь")
    }

    /// Повторный вызов с тем же значением — no-op (симметрично `modelVariant` guard'у).
    func testSetChatBaseModelWithSameValueIsNoOp() {
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { self.makeDataset() },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        let before = vm.chatBaseModel
        vm.setChatBaseModel(before)
        XCTAssertEqual(vm.chatBaseModel, before)
    }

    /// P5: смена базы во время генерации отменяет прогон — ответ не должен упасть
    /// в тред новой базы (симметрично `testSwitchingVariantDuringGenerationCancelsAndKeepsThreadsClean`).
    func testSetChatBaseModelDuringGenerationCancelsAndKeepsThreadsClean() async throws {
        let dataset = makeDataset()
        let provider = MockChatProvider(responses: [okResponse])
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
        vm.setChatBaseModel(FineTuneViewModel.smallModel)
        await task.value

        XCTAssertFalse(vm.isGenerating, "смена базы отменяет прогон")
        XCTAssertTrue(vm.messages.isEmpty, "тред новой базы пуст — ответ старой базы в него не упал")
        let oldBaseMessages = vm.threads["\(FineTuneModelVariant.baseline.rawValue)|\(MlxServerConfig.defaultModel)"]?.messages ?? []
        XCTAssertEqual(oldBaseMessages.filter { $0.role == "assistant" }.count, 0,
                       "ответ не дописался и в тред прежней базы — прогон отменён до завершения")
    }

    /// `.tuned` резолвит пару «база прогона + его адаптер» через `runs()` —
    /// сервер поднимается с моделью и adapterPath ИМЕННО finished-прогона выбранной базы.
    func testTunedSendUsesModelAndAdapterPathFromMatchingFinishedRun() async throws {
        let dataset = makeDataset()
        let adapterDir = tempDir.appendingPathComponent("adapters/Qwen2.5-3B-Instruct-4bit")
        try FileManager.default.createDirectory(at: adapterDir, withIntermediateDirectories: true)
        try Data().write(to: adapterDir.appendingPathComponent("adapters.safetensors"))
        let run = makeFinishedRun(workdir: dataset.workdir, model: FineTuneViewModel.smallModel,
                                  adapterPath: adapterDir.path)

        var recordedConfig: MlxServerConfig?
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { config in
                recordedConfig = config
                return MockChatProvider(responses: [self.okResponse])
            },
            dataset: { dataset },
            runs: { [run] },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.modelVariant = .tuned
        vm.setChatBaseModel(FineTuneViewModel.smallModel)
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertNil(vm.errorText)
        let config = try XCTUnwrap(recordedConfig)
        XCTAssertEqual(config.model, FineTuneViewModel.smallModel)
        XCTAssertEqual(config.adapterPath?.path, adapterDir.path)
    }

    /// `.tuned` на базе 3B без единой finished-записи — легаси-fallback запрещён (он
    /// только для дефолтной 7B), ошибка называет запрошенную базу по имени.
    func testTunedWithSmallBaseAndNoRunsShowsTunedRunMissingErrorMentioningModel() async {
        let dataset = makeDataset() // без легаси-адаптера и без прогонов
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { dataset },
            runs: { [] },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())
        vm.modelVariant = .tuned
        vm.setChatBaseModel(FineTuneViewModel.smallModel)
        vm.input = "фрагмент встречи"
        await vm.send()

        XCTAssertEqual(vm.errorText, FineTuneError.tunedRunMissing(model: FineTuneViewModel.smallModel).errorDescription)
        XCTAssertTrue(vm.errorText?.contains("3B") ?? false, "ошибка называет запрошенную (3B) базу")
        XCTAssertTrue(vm.messages.isEmpty)
    }

    /// `availableBaseModels` — дефолты (3B, 7B) + distinct-модели finished-прогонов
    /// этого workdir (задача 92, `TuneSelection.chatBaseModels`).
    func testAvailableBaseModelsContainsDefaultsAndFinishedRunModels() {
        let dataset = makeDataset()
        let customRun = makeFinishedRun(workdir: dataset.workdir, model: "custom-finetuned-model",
                                        adapterPath: "adapters/custom-finetuned-model")
        let otherWorkdirRun = makeFinishedRun(workdir: "other-dataset", model: "should-not-appear",
                                              adapterPath: "adapters/should-not-appear")
        let vm = TuningChatViewModel(
            server: makeReadyServer(),
            providerFactory: { _ in MockChatProvider(responses: [self.okResponse]) },
            dataset: { dataset },
            runs: { [customRun, otherWorkdirRun] },
            isTuneOrBaselineActive: { false },
            fileURL: tempFileURL())

        XCTAssertEqual(vm.availableBaseModels,
                       [FineTuneViewModel.smallModel, MlxServerConfig.defaultModel, "custom-finetuned-model"])
    }
}
