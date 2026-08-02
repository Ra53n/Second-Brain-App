// TuningChatStoreTests.swift — персистентность мини-чата тюнинга (задача 85, P2, задача
// 89 — раздельные треды по варианту): round-trip, карантин битого файла, миграция
// плоского старого документа в `threads`, незнакомый вариант в ключе не роняет декод.
// Задача 91: миграция документа без escalation-полей (тред/документ/сообщение), round-trip
// с заполненными escalationTarget/escalationEnabled/escalation.
// Задача 92: ключ треда — "<variant>|<model>"; легаси-ключи `baseline`/`tuned` (в т.ч.
// с escalation-полями эпохи 91) мигрируют на "…|<7B>"; round-trip `chatBaseModel`.
// Задача 93: round-trip документа с `EscalationTarget.kind == .localTuned`.
// Задача 94: миграция документа эпохи 93 без `stagesEnabled`/`stages` → false/nil;
// round-trip заполненных стадий (кириллица в промптах); незнакомое поле в объекте
// стадии («из будущего») не роняет декод.
// Задача 95: round-trip сообщения с `notImproved`+`strongReport`; JSON без `strongReport`
// в `escalation` мигрирует на nil.

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

    /// Задача 95: `notImproved` + `strongReport` — round-trip документа с сообщением,
    /// показавшим дешёвый ответ после строго худшей сильной ступени.
    func testRoundTripWithNotImprovedEscalationAndStrongReport() {
        let url = tempDir.appendingPathComponent("chat.json")
        let cheapReport = ConfidenceReport(verdict: .unsure, reasons: [], metrics: ConfidenceMetrics(totalCalls: 1), checks: [])
        let strongReport = ConfidenceReport(verdict: .fail, reasons: ["не распарсился"],
                                             metrics: ConfidenceMetrics(totalCalls: 1), checks: [])
        let escalation = EscalationRecord(status: .notImproved, trigger: .unsure, providerID: "mlx-local",
                                           model: "Qwen2.5-7B-Instruct-4bit", strongReport: strongReport)
        let document = TuningChatDocument(
            threads: [
                "baseline|\(legacy7B)": TuningChatThread(
                    messages: [
                        TuningChatMessage(role: "user", content: "Привет"),
                        TuningChatMessage(role: "assistant", content: "дешёвый ответ", report: cheapReport,
                                          modelVariant: "baseline", escalation: escalation),
                    ],
                    pipelineConfig: .default, escalationEnabled: true),
            ],
            modelVariant: "baseline",
            chatBaseModel: legacy7B)
        TuningChatPersistence.save(document, to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertEqual(loaded, document)
        let loadedEscalation = loaded.threads["baseline|\(legacy7B)"]?.messages[1].escalation
        XCTAssertEqual(loadedEscalation?.status, .notImproved)
        XCTAssertEqual(loadedEscalation?.strongReport, strongReport)
        XCTAssertNil(loadedEscalation?.primaryReport)
    }

    /// Записи эпохи ≤94 — JSON сообщения без `strongReport` в `escalation` — декодируются,
    /// `strongReport` дефолтится в `nil` (снисходительный декодер).
    func testMessageEscalationWithoutStrongReportFieldDecodesToNil() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"threads":{"baseline|\(legacy7B)":{"messages":[
            {"role":"assistant","content":"сильный ответ",
             "escalation":{"status":"succeeded","trigger":"unsure","providerID":"openai","model":"gpt-5"}}
        ],"pipelineConfig":{},"escalationEnabled":true}},"modelVariant":"baseline"}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        let loaded = TuningChatPersistence.load(from: url)
        let escalation = try XCTUnwrap(loaded.threads["baseline|\(legacy7B)"]?.messages.first?.escalation)
        XCTAssertEqual(escalation.status, .succeeded)
        XCTAssertNil(escalation.strongReport)
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

    // MARK: - Задача 94: multi-stage inference

    /// Документ эпохи 93 (до задачи 94): треды/документ не знают ни `stagesEnabled`,
    /// ни `stages` — миграция на дефолты, история цела.
    func testMigrationFromEpoch93DocumentWithoutStageFieldsDefaultsDisabledAndNilStages() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"threads":{"baseline|\(legacy7B)":{"messages":[
            {"id":"11111111-1111-1111-1111-111111111111","role":"user","content":"Привет"}],
            "pipelineConfig":{"constraintEnabled":true,"redundancyEnabled":false,"scoringEnabled":false,"selfCheckEnabled":false},
            "escalationEnabled":false}},
        "modelVariant":"baseline","chatBaseModel":"\(legacy7B)"}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)

        XCTAssertNil(loaded.stages, "поле stages появилось в задаче 94 — документ без него мигрирует на nil")
        let baselineThread = try XCTUnwrap(loaded.threads["baseline|\(legacy7B)"])
        XCTAssertFalse(baselineThread.stagesEnabled, "тумблер стадий мигрирует в false")
        XCTAssertEqual(baselineThread.messages.count, 1, "история цела")
    }

    /// Round-trip с заполненными стадиями (кириллица в промптах) и включённым тумблером —
    /// стадии per-document, тумблер per-thread.
    func testRoundTripWithStagesConfiguredAndCyrillicPrompts() {
        let url = tempDir.appendingPathComponent("chat.json")
        let stages = [
            InferenceStage(name: "Говорящие", prompt: "Перечисли говорящих: {{transcript}}"),
            InferenceStage(name: "Сборка", prompt: "Собери итог из {{stage:1}} и {{prev}}"),
        ]
        let document = TuningChatDocument(
            threads: ["baseline|\(legacy7B)": TuningChatThread(stagesEnabled: true)],
            modelVariant: "baseline", chatBaseModel: legacy7B, stages: stages)
        TuningChatPersistence.save(document, to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertEqual(loaded, document)
        XCTAssertEqual(loaded.stages, stages)
        XCTAssertTrue(loaded.threads["baseline|\(legacy7B)"]?.stagesEnabled ?? false)
    }

    /// Пустой (не nil) массив стадий — «пользователь удалил все явно» отличается от
    /// «не редактировал» (nil) и обязан пережить round-trip как есть.
    func testRoundTripDistinguishesNilStagesFromEmptyArray() {
        let url = tempDir.appendingPathComponent("chat.json")
        let document = TuningChatDocument(modelVariant: "baseline", chatBaseModel: legacy7B, stages: [])
        TuningChatPersistence.save(document, to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertNotNil(loaded.stages)
        XCTAssertEqual(loaded.stages, [])
    }

    /// Объект стадии «из будущего» с незнакомым дополнительным полем не роняет декод
    /// документа целиком — известные стадии и остальной документ целы.
    func testUnknownFieldInStageObjectDoesNotFailDocumentDecode() throws {
        let url = tempDir.appendingPathComponent("chat.json")
        let json = """
        {"threads":{},"modelVariant":"baseline",
        "stages":[{"id":"11111111-1111-1111-1111-111111111111","name":"Сборка","prompt":"p","modelHint":"gpt-6"}]}
        """
        try Data(json.utf8).write(to: url)
        let loaded = TuningChatPersistence.load(from: url)
        XCTAssertEqual(loaded.stages?.count, 1)
        XCTAssertEqual(loaded.stages?.first?.name, "Сборка")
        XCTAssertEqual(loaded.stages?.first?.prompt, "p")
    }
}
