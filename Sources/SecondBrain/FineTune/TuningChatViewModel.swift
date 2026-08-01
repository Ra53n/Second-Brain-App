// TuningChatViewModel.swift — единственный владелец состояния мини-чата тюнинга
// (задача 85). P5: `chatGen` — сверка после каждого await, clearChat() во время
// генерации инвалидирует её без падения. Redundancy = 3 полных ответа без
// стриминга — temperature 0.3, как снятие baseline (FineTuneRunner.baselineTemperature).
//
// Задача 89: `threads` (по варианту модели) — источник истины; `messages`/
// `pipelineConfig` остаются `@Published`-проекциями активного треда, чтобы не
// трогать вьюхи и тесты, завязанные на них. Единственная точка записи в тред —
// `syncActiveThread()`, зовётся после каждой мутации проекций перед `persistNow()`.
//
// Задача 91: каскадная эскалация — `escalationEnabled` тредовая (симметрично
// `pipelineConfig`), `escalationTarget` документная (доверенная сильная модель —
// свойство окружения, не варианта). Вторая ступень — обычный `ConfidencePipeline`
// поверх резолвнутого провайдера, `CancellationError` перебрасывается наверх и не
// деградирует в `.failed` (P5-отмена).
//
// Задача 92: ключ треда — `"<variant>|<chatBaseModel>"` (`threadKey`), база чата
// выбирается пикером (`chatBaseModel`, зеркально `modelVariant` — тот же P5-гейт
// отмены генерации и saveThread/persistNow). `.tuned` резолвится через
// `TuneSelection.selectTunedRun` по инжектированным `runs()`, легаси-путь
// (`adapters/adapters.safetensors` без per-model подкаталога) — только когда
// `TuneSelection.legacyAdapterFallback` разрешает.

import Foundation

@MainActor
final class TuningChatViewModel: ObservableObject {
    @Published var messages: [TuningChatMessage]
    @Published var input: String = ""
    @Published var modelVariant: FineTuneModelVariant {
        didSet {
            // Guard от повторного значения (SwiftUI шлёт то же значение при перерисовке)
            // и от бессмысленной пересинхронизации: без него каждый лишний didSet
            // затирал бы тред oldValue его же неизменёнными данными.
            guard modelVariant != oldValue else { return }
            // P5: UI блокирует переключение при генерации, но модель не полагается на
            // вёрстку — иначе программная смена варианта уронила бы ответ в чужой тред
            // (gen-гейт прошёл бы: chatGen не менялся). Зеркально clearChat().
            if isGenerating {
                chatGen += 1
                generationTask?.cancel()
                generationTask = nil
                isGenerating = false
                progressText = nil
            }
            saveThread(for: oldValue)
            let next = threads[threadKey(variant: modelVariant)] ?? TuningChatThread()
            messages = next.messages
            pipelineConfig = next.pipelineConfig
            escalationEnabled = next.escalationEnabled
            persistNow()
        }
    }
    @Published var pipelineConfig: ConfidencePipelineConfig
    @Published var escalationEnabled: Bool
    @Published var escalationTarget: EscalationTarget?
    /// База чата (задача 92) — свойство документа, не варианта: тред baseline↔тюн
    /// сравниваются на ОДНОЙ базе. Мутация — только через `setChatBaseModel(_:)`.
    @Published private(set) var chatBaseModel: String
    @Published private(set) var threads: [String: TuningChatThread]
    @Published private(set) var isGenerating = false
    @Published var progressText: String?
    @Published var errorText: String?
    /// Прогресс батч-прогона «текущий/всего» — nil вне прогона.
    @Published private(set) var batchProgress: (current: Int, total: Int)?
    @Published var batchErrorText: String?
    /// URL записанного `<variant>.md` последнего успешного батча — триггер
    /// перечитать отчёты (paths + summary.md) в UI.
    @Published private(set) var lastBatchReportURL: URL?

    private let server: MlxServerManager
    private let providerFactory: (MlxServerConfig) -> ChatProvider
    private let dataset: () -> FineTuneDataset?
    private let runs: () -> [FineTuneRun]
    private let isTuneOrBaselineActive: () -> Bool
    private let fileURL: URL
    private let systemPromptLoader: (FineTuneDataset) -> String?
    private let redundancyCount: Int
    private let escalationResolver: @MainActor (EscalationTarget?) -> EscalationResolution

    private var chatGen = 0
    /// Текущая генерация (send/runBatch) — держим Task, чтобы clearChat()/deinit
    /// могли реально прервать сеть (Task.cancel(), не только `chatGen`-гейт),
    /// иначе до 5 фоновых вызовов к mlx доезжают вхолостую после очистки чата.
    private var generationTask: Task<Void, Never>?

    init(server: MlxServerManager,
         providerFactory: @escaping (MlxServerConfig) -> ChatProvider = { MlxChatProvider(port: $0.port) },
         dataset: @escaping () -> FineTuneDataset?,
         runs: @escaping () -> [FineTuneRun] = { [] },
         isTuneOrBaselineActive: @escaping () -> Bool,
         fileURL: URL = TuningChatPersistence.defaultFileURL,
         systemPromptLoader: @escaping (FineTuneDataset) -> String? = TuningChatViewModel.defaultSystemPromptLoader,
         redundancyCount: Int = 3,
         escalationResolver: @escaping @MainActor (EscalationTarget?) -> EscalationResolution = { _ in
             .unavailable(reason: "модель эскалации не выбрана")
         }) {
        self.server = server
        self.providerFactory = providerFactory
        self.dataset = dataset
        self.runs = runs
        self.isTuneOrBaselineActive = isTuneOrBaselineActive
        self.fileURL = fileURL
        self.systemPromptLoader = systemPromptLoader
        self.redundancyCount = redundancyCount
        self.escalationResolver = escalationResolver

        let document = TuningChatPersistence.load(from: fileURL)
        threads = document.threads
        let variant = FineTuneModelVariant(rawValue: document.modelVariant) ?? .baseline
        modelVariant = variant
        let model = document.chatBaseModel ?? MlxServerConfig.defaultModel
        chatBaseModel = model
        let activeThread = document.threads[TuningChatViewModel.threadKey(variant: variant, model: model)]
            ?? TuningChatThread()
        messages = activeThread.messages
        pipelineConfig = activeThread.pipelineConfig
        escalationEnabled = activeThread.escalationEnabled
        escalationTarget = document.escalationTarget
    }

    /// Тумблер действует только на следующее сообщение (допущение задачи 86) — точка
    /// изменения нужна одна, чтобы выбор пережил перезапуск.
    func setPipelineConfig(_ config: ConfidencePipelineConfig) {
        pipelineConfig = config
        syncActiveThread()
        persistNow()
    }

    /// Тумблер эскалации действует только на следующее сообщение активного треда —
    /// симметрично `setPipelineConfig`.
    func setEscalationEnabled(_ enabled: Bool) {
        escalationEnabled = enabled
        syncActiveThread()
        persistNow()
    }

    /// Цель эскалации — свойство документа, не треда/варианта: доверенная сильная
    /// модель одна на весь чат тюнинга.
    func setEscalationTarget(_ target: EscalationTarget?) {
        escalationTarget = target
        // Поле документное, но контракт makeDocument требует синхронизацию перед каждым
        // сохранением — иначе несинхронизированные проекции треда уехали бы на диск.
        syncActiveThread()
        persistNow()
    }

    /// База чата (задача 92) — смена зеркальна `modelVariant.didSet`: генерация
    /// отменяется (программная смена не должна уронить ответ в чужой тред), старый
    /// тред сохраняется под своим ключом, новый — загружается.
    func setChatBaseModel(_ model: String) {
        guard model != chatBaseModel else { return }
        if isGenerating {
            chatGen += 1
            generationTask?.cancel()
            generationTask = nil
            isGenerating = false
            progressText = nil
        }
        // Старый тред сохраняется, ПОКА chatBaseModel ещё старый — threadKey(variant:)
        // читает его из self.
        saveThread(for: modelVariant)
        chatBaseModel = model
        let next = threads[threadKey(variant: modelVariant)] ?? TuningChatThread()
        messages = next.messages
        pipelineConfig = next.pipelineConfig
        escalationEnabled = next.escalationEnabled
        persistNow()
    }

    /// Базы для пикера: дефолты (3B, 7B) + distinct-модели завершённых прогонов этого
    /// workdir (задача 92, TuneSelection.chatBaseModels).
    var availableBaseModels: [String] {
        let workdir = dataset()?.workdir ?? ""
        return TuneSelection.chatBaseModels(runs: runs(), workdir: workdir,
                                            defaults: [FineTuneViewModel.smallModel, MlxServerConfig.defaultModel])
    }

    /// Ключ треда — `"<variant.rawValue>|<chatBaseModel>"`: статистика per (variant,
    /// база) раздельная, переключение базы не смешивает историю разных моделей.
    private func threadKey(variant: FineTuneModelVariant) -> String {
        TuningChatViewModel.threadKey(variant: variant, model: chatBaseModel)
    }

    private static func threadKey(variant: FineTuneModelVariant, model: String) -> String {
        "\(variant.rawValue)|\(model)"
    }

    /// Пишет проекции (`messages`/`pipelineConfig`/`escalationEnabled`) в тред активного
    /// варианта — единая точка синхронизации перед каждым `persistNow()`.
    private func syncActiveThread() {
        saveThread(for: modelVariant)
    }

    private func saveThread(for variant: FineTuneModelVariant) {
        threads[threadKey(variant: variant)] = TuningChatThread(
            messages: messages, pipelineConfig: pipelineConfig, escalationEnabled: escalationEnabled)
    }

    var sessionStats: TuningChatSessionStats? {
        TuningChatSessionStats.compute(messages: messages)
    }

    /// Отчёт последнего ответа активного треда — для блока «Последний запрос» (задача 90).
    var lastReport: ConfidenceReport? {
        messages.last(where: { $0.role == "assistant" })?.report
    }

    /// Запись эскалации последнего ответа активного треда — рядом с `lastReport`.
    var lastEscalation: EscalationRecord? {
        messages.last(where: { $0.role == "assistant" })?.escalation
    }

    nonisolated static func defaultSystemPromptLoader(dataset: FineTuneDataset) -> String? {
        guard let path = dataset.systemPromptPath else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Адаптер под `.tuned` — `<workdir>/adapters/adapters.safetensors` (train.py).
    private static let adapterRelativePath = "adapters/adapters.safetensors"

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        guard !isTuneOrBaselineActive() else {
            errorText = FineTuneError.tuneActive.errorDescription
            return
        }
        guard let dataset = dataset() else {
            errorText = FineTuneError.datasetNotFound.errorDescription
            return
        }

        let variant = modelVariant
        let baseModel = chatBaseModel
        let config: MlxServerConfig
        switch variant {
        case .baseline:
            config = MlxServerConfig(model: baseModel)
        case .tuned:
            if let run = TuneSelection.selectTunedRun(runs: runs(), workdir: dataset.workdir, baseModel: baseModel) {
                let adapterURL = URL(fileURLWithPath: run.adapterPath)
                guard FileManager.default.fileExists(atPath: adapterURL.appendingPathComponent("adapters.safetensors").path)
                else {
                    errorText = FineTuneError.adapterMissing.errorDescription
                    return
                }
                config = MlxServerConfig(model: run.model, adapterPath: adapterURL)
            } else if TuneSelection.legacyAdapterFallback(runs: runs(), workdir: dataset.workdir, baseModel: baseModel) {
                let adapterURL = dataset.rootURL.appendingPathComponent(Self.adapterRelativePath)
                guard FileManager.default.fileExists(atPath: adapterURL.path) else {
                    errorText = FineTuneError.adapterMissing.errorDescription
                    return
                }
                config = MlxServerConfig(model: baseModel, adapterPath: adapterURL.deletingLastPathComponent())
            } else {
                errorText = FineTuneError.tunedRunMissing(model: baseModel).errorDescription
                return
            }
        }

        chatGen += 1
        let gen = chatGen
        isGenerating = true
        errorText = nil
        progressText = nil
        input = ""
        messages.append(TuningChatMessage(role: "user", content: text))
        syncActiveThread()
        persistNow()

        let provider = providerFactory(config)
        let system = systemPromptLoader(dataset) ?? ""
        let settings = ChatSettings(model: config.model, temperature: FineTuneRunner.baselineTemperature)
        let pipeline = ConfidencePipeline(provider: provider, settings: settings, redundancyCount: redundancyCount,
                                           config: pipelineConfig)
        // Снимок ДО Task: тумблер/цель/конфиг эскалации не должны подхватить
        // изменение, сделанное пользователем, пока запрос уже летит.
        let escalationEnabledSnapshot = escalationEnabled
        let escalationTargetSnapshot = escalationTarget
        let escalationConfig = EscalationCore.escalationPipelineConfig(from: pipelineConfig)

        // Task, а не голый await: clearChat()/deinit зовут Task.cancel() — без него
        // отмена была бы только косметической (chatGen-гейт режет запись результата,
        // но уже запущенные вызовы к mlx всё равно доезжают вхолостую).
        let task = Task { [self] in
            do {
                try await server.ensureRunning(config)
                guard gen == chatGen else { return }
                let result = try await pipeline.run(system: system, transcript: text, reference: nil) { step in
                    Task { @MainActor [self] in
                        guard gen == self.chatGen else { return }
                        self.progressText = step
                    }
                }
                guard gen == chatGen else { return }

                var attempt: EscalationCore.Attempt?
                if EscalationCore.shouldEscalate(enabled: escalationEnabledSnapshot, verdict: result.report.verdict) {
                    switch escalationResolver(escalationTargetSnapshot) {
                    case let .unavailable(reason):
                        attempt = .unavailable(reason: reason)
                    case let .resolved(strong):
                        progressText = "Эскалация: \(strong.displayName)…"
                        let strongSettings = ChatSettings(model: strong.model, temperature: FineTuneRunner.baselineTemperature)
                        let strongPipeline = ConfidencePipeline(provider: strong.provider, settings: strongSettings,
                                                                 redundancyCount: redundancyCount, config: escalationConfig)
                        do {
                            let strongResult = try await strongPipeline.run(system: system, transcript: text, reference: nil) { step in
                                Task { @MainActor [self] in
                                    guard gen == self.chatGen else { return }
                                    self.progressText = "Эскалация: \(step)"
                                }
                            }
                            guard gen == chatGen else { return }
                            attempt = .succeeded(answer: strongResult.answerRaw, report: strongResult.report,
                                                  providerID: strong.providerID.rawValue, model: strong.model)
                        } catch is CancellationError {
                            throw CancellationError() // не деградирует в .failed — ловит внешний catch
                        } catch {
                            guard gen == chatGen else { return }
                            attempt = .failed(reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                                               providerID: strong.providerID.rawValue, model: strong.model)
                        }
                    }
                }

                guard gen == chatGen else { return }
                let composed = EscalationCore.composeMessage(primaryAnswer: result.answerRaw, primaryReport: result.report,
                                                              attempt: attempt)
                messages.append(TuningChatMessage(role: "assistant", content: composed.content, report: composed.report,
                                                   modelVariant: variant.rawValue, escalation: composed.escalation))
                isGenerating = false
                progressText = nil
                generationTask = nil
                syncActiveThread()
                persistNow()
            } catch is CancellationError {
                guard gen == chatGen else { return }
                isGenerating = false
                progressText = nil
                generationTask = nil
            } catch {
                guard gen == chatGen else { return }
                isGenerating = false
                progressText = nil
                generationTask = nil
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        generationTask = task
        await task.value
    }

    func clearChat() {
        chatGen += 1
        generationTask?.cancel()
        generationTask = nil
        messages = []
        errorText = nil
        progressText = nil
        // Очистка доступна и во время батча (задача 87): отменённый прогон обязан
        // сбросить и свои поля — иначе счётчик «N/M» замерзает на экране навсегда
        // (гейт `gen == chatGen` в catch уже провален и сам их не сбросит).
        batchProgress = nil
        batchErrorText = nil
        isGenerating = false
        syncActiveThread()
        persistNow()
    }

    deinit {
        generationTask?.cancel()
    }

    func persistNow() {
        TuningChatPersistence.save(makeDocument(), to: fileURL)
    }

    /// Общая точка сборки документа (паттерн `FineTuneStore.makeDocument`) — вызывающий
    /// код обязан звать `syncActiveThread()` перед мутацией, которую хочет сохранить.
    private func makeDocument() -> TuningChatDocument {
        TuningChatDocument(threads: threads, modelVariant: modelVariant.rawValue,
                          escalationTarget: escalationTarget, chatBaseModel: chatBaseModel)
    }

    // MARK: - Батч-прогон (задача 85, критерий 6)

    /// Отчёты батча уже на диске: пути + распарсенный текст `summary.md` для
    /// рендера в UI. Читается по явному запросу вызывающего (не в SwiftUI body).
    struct BatchReportsSnapshot: Equatable {
        var baselineURL: URL?
        var tunedURL: URL?
        var summaryURL: URL?
        var summaryText: String?
    }

    func batchReportsSnapshot() -> BatchReportsSnapshot? {
        guard let dataset = dataset() else { return nil }
        let dir = dataset.rootURL.appendingPathComponent("confidence")
        let fm = FileManager.default
        let baseline = dir.appendingPathComponent("baseline.md")
        let tuned = dir.appendingPathComponent("tuned.md")
        let summary = dir.appendingPathComponent("summary.md")
        return BatchReportsSnapshot(
            baselineURL: fm.fileExists(atPath: baseline.path) ? baseline : nil,
            tunedURL: fm.fileExists(atPath: tuned.path) ? tuned : nil,
            summaryURL: fm.fileExists(atPath: summary.path) ? summary : nil,
            summaryText: try? String(contentsOf: summary, encoding: .utf8))
    }

    /// Тонкая обёртка над `ConfidenceBatchRunner` (P1 ядро — там же). Тот же
    /// `chatGen`/`isGenerating`, что и `send()` — второй одновременный
    /// батч/отправка сообщения исключены общим гейтом (допущение задачи).
    func runBatch(variant: FineTuneModelVariant) async {
        guard !isGenerating else { return }
        guard !isTuneOrBaselineActive() else {
            batchErrorText = FineTuneError.tuneActive.errorDescription
            return
        }
        guard let dataset = dataset() else {
            batchErrorText = FineTuneError.datasetNotFound.errorDescription
            return
        }

        var adapterPath: URL?
        if variant == .tuned {
            let adapterURL = dataset.rootURL.appendingPathComponent(Self.adapterRelativePath)
            guard FileManager.default.fileExists(atPath: adapterURL.path) else {
                batchErrorText = FineTuneError.adapterMissing.errorDescription
                return
            }
            adapterPath = dataset.rootURL.appendingPathComponent("adapters")
        }

        chatGen += 1
        let gen = chatGen
        isGenerating = true
        batchErrorText = nil
        batchProgress = (0, 0)

        let config = MlxServerConfig(adapterPath: adapterPath)
        let provider = providerFactory(config)
        let system = systemPromptLoader(dataset) ?? ""
        let runner = ConfidenceBatchRunner(redundancyCount: redundancyCount)

        // См. send(): Task, а не голый await — clearChat()/deinit зовут Task.cancel(),
        // иначе фоновые вызовы батча к mlx доезжают вхолостую после отмены.
        let task = Task { [self] in
            do {
                try await server.ensureRunning(config)
                guard gen == chatGen else { return }
                let url = try await runner.run(dataset: dataset, variant: variant, provider: provider, system: system) {
                    current, total in
                    Task { @MainActor [self] in
                        guard gen == chatGen else { return }
                        batchProgress = (current, total)
                    }
                }
                guard gen == chatGen else { return }
                lastBatchReportURL = url
                isGenerating = false
                batchProgress = nil
                generationTask = nil
            } catch is CancellationError {
                guard gen == chatGen else { return }
                isGenerating = false
                batchProgress = nil
                generationTask = nil
            } catch {
                guard gen == chatGen else { return }
                isGenerating = false
                batchProgress = nil
                generationTask = nil
                batchErrorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        generationTask = task
        await task.value
    }
}
