// TuningChatViewModelTests.swift — мини-чат тюнинга (задача 85, P5): guard тюна/baseline,
// adapterMissing на `.tuned` без адаптера, успешный send добавляет 2 сообщения и
// персистит, clearChat во время генерации не роняет и не воскрешает поздний ответ.

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
    private func makeReadyServer() -> MlxServerManager {
        var spawned = false
        return MlxServerManager(
            registry: BackgroundProcessRegistry(),
            idlePolicy: IdleShutdownPolicy(timeout: 600, clock: { 0 }),
            spawn: { _, _ in spawned = true; return MockManagedProcess() },
            health: { _ in spawned },
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
        XCTAssertEqual(persisted.messages.count, 2)
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
}
