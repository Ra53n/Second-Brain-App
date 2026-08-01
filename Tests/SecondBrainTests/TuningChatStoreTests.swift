// TuningChatStoreTests.swift — персистентность мини-чата тюнинга (задача 85, P2, задача
// 89 — раздельные треды по варианту): round-trip, карантин битого файла, миграция
// плоского старого документа в `threads`, незнакомый вариант в ключе не роняет декод.
// Задача 91: миграция документа без escalation-полей (тред/документ/сообщение), round-trip
// с заполненными escalationTarget/escalationEnabled/escalation.
// Задача 92: ключ треда — "<variant>|<model>"; легаси-ключи `baseline`/`tuned` (в т.ч.
// с escalation-полями эпохи 91) мигрируют на "…|<7B>"; round-trip `chatBaseModel`.
// Задача 93: round-trip документа с `EscalationTarget.kind == .localTuned`.

import XCTest
@testable import SecondBrain

final class TuningChatStoreTests: XCTestCase {
    private var tempDir: URL!
    /// База, на которую мигрируют легаси-ключи `baseline`/`tuned` (единственная до задачи 92).
    private let legacy7B = MlxServerConfig.defaultModel

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRoundTrip() {
        let url = tempDir.appendingPathComponent("chat.json")
        let report = ConfidenceReport(
            verdict: .ok, reasons: ["ок"], metrics: ConfidenceMetrics(totalCalls: 1),
            checks: [ConfidenceCheckSummary(name: "валидный JSON", status: "pass", detail: nil)])
        let document = TuningChatDocument(
            threads: [
                "baseline|\(legacy7B)": TuningChatThread(
                    messages: [
                        TuningChatMessage(role: "user", content: "Привет"),
                        TuningChatMessage(role: "assistant", content: "{\"action_items\":[]}",
                                          report: report, modelVariant: "baseline"),
                    ],
                    pipelineConfig: .default),
                "tuned|\(legacy7B)": TuningChatThread(messages: [], pipelineConfig: .allEnabled),
            ],
            modelVariant: "tuned", chatBaseModel: legacy7B)
        TuningChatPersistence.save(document, to: url)
        XCTAssertEqual(TuningChatPersistence.load(from: url), document)
    }

    /// Ключи уже нового формата (с `|`) не трогаются миграцией легаси-ключей — round-trip
    /// с базой 3B, отличной от легаси-7B.
    func testRoundTripWithNonDefaultChatBaseModel() {
        let url = tempDir.appendingPathComponent("chat.json")
        let smallModel = FineTuneViewModel.smallModel
        let document = TuningChatDocument(
            threads: ["tuned|\(smallModel)": TuningChatThread(messages: [TuningChatMessage(role: "user", content: "3B")])],
            modelVariant: "tuned", chatBaseModel: smallModel)
        TuningChatPersistence.save(document, to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertEqual(loaded, document)
        XCTAssertEqual(loaded.chatBaseModel, smallModel)
    }

    func testCorruptFileIsQuarantinedAndReturnsEmptyDocument() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        try Data("не json вовсе".utf8).write(to: url)
        XCTAssertEqual(TuningChatPersistence.load(from: url), TuningChatDocument())
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingFileReturnsEmptyDocument() {
        let url = tempDir.appendingPathComponent("missing.json")
        XCTAssertEqual(TuningChatPersistence.load(from: url), TuningChatDocument())
    }

    /// Задача 89: старый плоский документ (`messages`/`pipelineConfig` на верхнем уровне,
    /// без `threads`) — история целиком уезжает в тред активного `modelVariant`,
    /// конфиг копируется в оба треда, ничего не теряется.
    func testMigrationFromFlatDocumentMovesMessagesToActiveThreadAndConfigToBoth() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"messages":[{"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"Привет"}],
        "modelVariant":"tuned",
        "pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":true,"scoringEnabled":false,"selfCheckEnabled":true}}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)

        XCTAssertEqual(loaded.modelVariant, "tuned")
        XCTAssertNil(loaded.chatBaseModel, "плоский документ до задачи 92 базу чата не знал")
        let tunedThread = try XCTUnwrap(loaded.threads["tuned|\(legacy7B)"])
        XCTAssertEqual(tunedThread.messages.count, 1)
        XCTAssertEqual(tunedThread.messages[0].content, "Привет")
        let expectedConfig = ConfidencePipelineConfig(constraintEnabled: true, redundancyEnabled: true,
                                                        scoringEnabled: false, selfCheckEnabled: true)
        XCTAssertEqual(tunedThread.pipelineConfig, expectedConfig)

        let baselineThread = try XCTUnwrap(loaded.threads["baseline|\(legacy7B)"])
        XCTAssertTrue(baselineThread.messages.isEmpty, "история user-сообщений в baseline не расщепляется")
        XCTAssertEqual(baselineThread.pipelineConfig, expectedConfig, "конфиг копируется в оба треда")
    }

    /// Поля report/modelVariant/createdAt появились позже — старый JSON без них грузится с дефолтами.
    func testMigrationFromMinimalJSON() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"messages":[{"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"Привет"}],"modelVariant":"tuned"}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)
        let tunedThread = try XCTUnwrap(loaded.threads["tuned|\(legacy7B)"])
        XCTAssertEqual(tunedThread.messages.count, 1)
        XCTAssertEqual(tunedThread.messages[0].content, "Привет")
        XCTAssertNil(tunedThread.messages[0].report)
        XCTAssertNil(tunedThread.messages[0].modelVariant)
        XCTAssertEqual(loaded.modelVariant, "tuned")
        XCTAssertEqual(tunedThread.pipelineConfig, .default, "поле появилось в задаче 86 — старый документ мигрирует на дефолт")
    }

    /// `pipelineConfig` появилось в задаче 86 — старый `finetune-chat.json` без него
    /// обязан грузиться с продовым дефолтом (только constraint), не падать.
    func testPipelineConfigMigratesToDefaultWhenAbsent() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = "{\"messages\":[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"role\":\"user\",\"content\":\"x\"}],\"modelVariant\":\"baseline\"}"
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)
        let baselineThread = try XCTUnwrap(loaded.threads["baseline|\(legacy7B)"])
        XCTAssertEqual(baselineThread.pipelineConfig, ConfidencePipelineConfig(
            constraintEnabled: true, redundancyEnabled: false, scoringEnabled: false, selfCheckEnabled: false))
    }

    func testPipelineConfigRoundTripsWithAllFlagsSet() {
        let url = tempDir.appendingPathComponent("chat.json")
        let config = ConfidencePipelineConfig(constraintEnabled: true, redundancyEnabled: true,
                                               scoringEnabled: false, selfCheckEnabled: true)
        // Ключ "baseline" (без "|") — легаси, мигрирует на "baseline|<7B>" при загрузке.
        let document = TuningChatDocument(threads: ["baseline": TuningChatThread(pipelineConfig: config)])
        TuningChatPersistence.save(document, to: url)
        XCTAssertEqual(TuningChatPersistence.load(from: url).threads["baseline|\(legacy7B)"]?.pipelineConfig, config)
    }

    /// `chatBaseModel` появилось в задаче 92 — старый документ без него грузится с nil,
    /// решение о дефолте (7B) — за VM, не за стором.
    func testChatBaseModelMigratesToNilWhenAbsent() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"threads":{"baseline":{"messages":[],"pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":false,"scoringEnabled":false,"selfCheckEnabled":false}}},
        "modelVariant":"baseline"}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertNil(loaded.chatBaseModel)
        XCTAssertNotNil(loaded.threads["baseline|\(legacy7B)"])
    }

    /// Литеральный JSON эпохи 91 (до задачи 92): треды ключами `baseline`/`tuned`,
    /// escalation-поля документа/треда/сообщения заполнены. Ключи мигрируют на "…|<7B>",
    /// вся история и escalation-записи целы, `chatBaseModel` отсутствует → nil.
    func testMigrationFromEpoch91DocumentPreservesEscalationAndMigratesKeys() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"threads":{
            "baseline":{"messages":[
                {"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"Привет"},
                {"id":"22222222-2222-2222-2222-222222222222","role":"assistant","content":"ответ",
                 "modelVariant":"baseline",
                 "escalation":{"status":"succeeded","trigger":"unsure","providerID":"openai","model":"gpt-5"}}
            ],
            "pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":false,"scoringEnabled":false,"selfCheckEnabled":false},
            "escalationEnabled":true},
            "tuned":{"messages":[],
            "pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":true,"scoringEnabled":true,"selfCheckEnabled":true},
            "escalationEnabled":false}
        },
        "modelVariant":"baseline",
        "escalationTarget":{"providerID":"openai","model":"gpt-5"}}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)

        XCTAssertNil(loaded.chatBaseModel, "эпоха 91 базу чата не знала")
        XCTAssertEqual(loaded.escalationTarget, EscalationTarget(providerID: "openai", model: "gpt-5"))
        XCTAssertNil(loaded.threads["baseline"], "легаси-ключ переименован, не оставлен как есть")
        XCTAssertNil(loaded.threads["tuned"])

        let baselineThread = try XCTUnwrap(loaded.threads["baseline|\(legacy7B)"])
        XCTAssertEqual(baselineThread.messages.count, 2, "история цела")
        XCTAssertTrue(baselineThread.escalationEnabled)
        let escalation = try XCTUnwrap(baselineThread.messages[1].escalation)
        XCTAssertEqual(escalation.status, .succeeded)
        XCTAssertEqual(escalation.providerID, "openai")
        XCTAssertEqual(escalation.model, "gpt-5")

        let tunedThread = try XCTUnwrap(loaded.threads["tuned|\(legacy7B)"])
        XCTAssertTrue(tunedThread.messages.isEmpty)
        XCTAssertFalse(tunedThread.escalationEnabled)
    }

    func testEmptyJSONObjectMigratesToEmptyDocument() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(TuningChatPersistence.load(from: url), TuningChatDocument())
    }

    // MARK: - Задача 91: каскадная эскалация

    /// Документ ДО задачи 91: threads с messages/pipelineConfig, но без escalation-полей
    /// нигде (ни `escalationEnabled` в треде, ни `escalationTarget` в документе, ни
    /// `escalation` в сообщении) — миграция на дефолты, без потерь истории.
    func testMigrationFromPreEscalationDocumentDefaultsAllNewFields() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"threads":{"baseline":{"messages":[{"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"Привет"},
        {"id":"22222222-2222-2222-2222-222222222222","role":"assistant","content":"{}"}],
        "pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":false,"scoringEnabled":false,"selfCheckEnabled":false}}},
        "modelVariant":"baseline"}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)

        XCTAssertNil(loaded.escalationTarget, "документная цель эскалации появилась в задаче 91")
        let baselineThread = try XCTUnwrap(loaded.threads["baseline|\(legacy7B)"])
        XCTAssertFalse(baselineThread.escalationEnabled, "тумблер эскалации мигрирует в false")
        XCTAssertEqual(baselineThread.messages.count, 2, "история цела")
        XCTAssertNil(baselineThread.messages[0].escalation)
        XCTAssertNil(baselineThread.messages[1].escalation)
    }

    /// Совсем старый плоский документ (задача 85, до треды/эскалации) — та же миграция
    /// на дефолты, но ещё и через ветку плоского документа `init(from:)`.
    func testMigrationFromFlatPreEscalationDocumentDefaultsEscalationFields() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"messages":[{"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"Привет"}],
        "modelVariant":"baseline",
        "pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":false,"scoringEnabled":false,"selfCheckEnabled":false}}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)

        XCTAssertNil(loaded.escalationTarget)
        let baselineThread = try XCTUnwrap(loaded.threads["baseline|\(legacy7B)"])
        XCTAssertFalse(baselineThread.escalationEnabled)
        XCTAssertEqual(baselineThread.messages.count, 1)
    }

    func testRoundTripWithEscalationTargetEnabledAndMessageRecord() {
        let url = tempDir.appendingPathComponent("chat.json")
        let cheapReport = ConfidenceReport(verdict: .unsure, reasons: ["предупреждение"],
                                            metrics: ConfidenceMetrics(totalCalls: 1), checks: [])
        let strongReport = ConfidenceReport(verdict: .ok, reasons: [],
                                             metrics: ConfidenceMetrics(totalCalls: 1), checks: [])
        let escalation = EscalationRecord(status: .succeeded, trigger: .unsure, providerID: "openai",
                                           model: "gpt-5", primaryReport: cheapReport)
        // Ключ уже нового формата ("|") — не трогается миграцией легаси-ключей,
        // round-trip сохраняет объект как есть.
        let document = TuningChatDocument(
            threads: [
                "baseline|\(legacy7B)": TuningChatThread(
                    messages: [
                        TuningChatMessage(role: "user", content: "Привет"),
                        TuningChatMessage(role: "assistant", content: "сильный ответ", report: strongReport,
                                          modelVariant: "baseline", escalation: escalation),
                    ],
                    pipelineConfig: .default, escalationEnabled: true),
            ],
            modelVariant: "baseline",
            escalationTarget: EscalationTarget(providerID: "openai", model: "gpt-5"),
            chatBaseModel: legacy7B)
        TuningChatPersistence.save(document, to: url)
        XCTAssertEqual(TuningChatPersistence.load(from: url), document)
    }

    /// Задача 93: цель эскалации `.localTuned` (сентинел providerID "mlx-local") —
    /// `kind` не теряется при записи/чтении, документ переживает round-trip как есть.
    func testRoundTripWithLocalTunedEscalationTarget() {
        let url = tempDir.appendingPathComponent("chat.json")
        let document = TuningChatDocument(
            threads: ["baseline|\(legacy7B)": TuningChatThread(escalationEnabled: true)],
            modelVariant: "baseline",
            escalationTarget: EscalationTarget(providerID: .localTunedProviderID,
                                                model: "Qwen2.5-7B-Instruct-4bit", kind: .localTuned),
            chatBaseModel: legacy7B)
        TuningChatPersistence.save(document, to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertEqual(loaded, document)
        XCTAssertEqual(loaded.escalationTarget?.kind, .localTuned)
        XCTAssertEqual(loaded.escalationTarget?.providerID, ProviderID(rawValue: "mlx-local"))
    }

    /// Файл эпохи 91/92 (без `kind` в `escalationTarget`) — миграция на `.registry`, не краш.
    func testEscalationTargetWithoutKindInDocumentMigratesToRegistry() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"threads":{},"modelVariant":"baseline",
        "escalationTarget":{"providerID":"openai","model":"gpt-5"}}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertEqual(loaded.escalationTarget?.kind, .registry)
    }

    /// Новый формат: незнакомый вариант в ключе `threads` («значение из будущего») —
    /// декод не падает, известные треды целы. Ключ `baseline` (без `|`) всё ещё легаси —
    /// мигрирует на `baseline|<7B>`; `future-variant` (без `|`, не baseline/tuned) не трогается.
    func testUnknownVariantKeyInThreadsDoesNotFailDecodeAndKeepsKnownThreads() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"threads":{"baseline":{"messages":[],"pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":false,"scoringEnabled":false,"selfCheckEnabled":false}},
        "future-variant":{"messages":[{"id":"22222222-2222-2222-2222-222222222222","role":"user","content":"из будущего"}],"pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":false,"scoringEnabled":false,"selfCheckEnabled":false}}},
        "modelVariant":"baseline"}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertEqual(loaded.modelVariant, "baseline")
        XCTAssertNil(loaded.threads["baseline"], "легаси-ключ переименован")
        XCTAssertNotNil(loaded.threads["baseline|\(legacy7B)"])
        XCTAssertNotNil(loaded.threads["future-variant"], "незнакомый тред сохраняется как есть, не выбрасывается")
    }
}
