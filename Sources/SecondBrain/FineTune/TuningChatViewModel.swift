// TuningChatViewModel.swift — единственный владелец состояния мини-чата тюнинга
// (задача 85). P5: `chatGen` — сверка после каждого await, clearChat() во время
// генерации инвалидирует её без падения. Redundancy = 3 полных ответа без
// стриминга — temperature 0.3, как снятие baseline (FineTuneRunner.baselineTemperature).

import Foundation

@MainActor
final class TuningChatViewModel: ObservableObject {
    @Published var messages: [TuningChatMessage]
    @Published var input: String = ""
    @Published var modelVariant: FineTuneModelVariant
    @Published var pipelineConfig: ConfidencePipelineConfig
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
    private let isTuneOrBaselineActive: () -> Bool
    private let fileURL: URL
    private let systemPromptLoader: (FineTuneDataset) -> String?
    private let redundancyCount: Int

    private var chatGen = 0
    /// Текущая генерация (send/runBatch) — держим Task, чтобы clearChat()/deinit
    /// могли реально прервать сеть (Task.cancel(), не только `chatGen`-гейт),
    /// иначе до 5 фоновых вызовов к mlx доезжают вхолостую после очистки чата.
    private var generationTask: Task<Void, Never>?

    init(server: MlxServerManager,
         providerFactory: @escaping (MlxServerConfig) -> ChatProvider = { MlxChatProvider(port: $0.port) },
         dataset: @escaping () -> FineTuneDataset?,
         isTuneOrBaselineActive: @escaping () -> Bool,
         fileURL: URL = TuningChatPersistence.defaultFileURL,
         systemPromptLoader: @escaping (FineTuneDataset) -> String? = TuningChatViewModel.defaultSystemPromptLoader,
         redundancyCount: Int = 3) {
        self.server = server
        self.providerFactory = providerFactory
        self.dataset = dataset
        self.isTuneOrBaselineActive = isTuneOrBaselineActive
        self.fileURL = fileURL
        self.systemPromptLoader = systemPromptLoader
        self.redundancyCount = redundancyCount

        let document = TuningChatPersistence.load(from: fileURL)
        messages = document.messages
        modelVariant = FineTuneModelVariant(rawValue: document.modelVariant) ?? .baseline
        pipelineConfig = document.pipelineConfig
    }

    /// Тумблер действует только на следующее сообщение (допущение задачи 86) — точка
    /// изменения нужна одна, чтобы выбор пережил перезапуск.
    func setPipelineConfig(_ config: ConfidencePipelineConfig) {
        pipelineConfig = config
        persistNow()
    }

    var sessionStats: TuningChatSessionStats? {
        TuningChatSessionStats.compute(messages: messages)
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
        var adapterPath: URL?
        if variant == .tuned {
            let adapterURL = dataset.rootURL.appendingPathComponent(Self.adapterRelativePath)
            guard FileManager.default.fileExists(atPath: adapterURL.path) else {
                errorText = FineTuneError.adapterMissing.errorDescription
                return
            }
            adapterPath = dataset.rootURL.appendingPathComponent("adapters")
        }

        chatGen += 1
        let gen = chatGen
        isGenerating = true
        errorText = nil
        progressText = nil
        input = ""
        messages.append(TuningChatMessage(role: "user", content: text))
        persistNow()

        let config = MlxServerConfig(adapterPath: adapterPath)
        let provider = providerFactory(config)
        let system = systemPromptLoader(dataset) ?? ""
        let settings = ChatSettings(model: config.model, temperature: FineTuneRunner.baselineTemperature)
        let pipeline = ConfidencePipeline(provider: provider, settings: settings, redundancyCount: redundancyCount,
                                           config: pipelineConfig)

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
                messages.append(TuningChatMessage(role: "assistant", content: result.answerRaw,
                                                   report: result.report, modelVariant: variant.rawValue))
                isGenerating = false
                progressText = nil
                generationTask = nil
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
        persistNow()
    }

    deinit {
        generationTask?.cancel()
    }

    func persistNow() {
        TuningChatPersistence.save(
            TuningChatDocument(messages: messages, modelVariant: modelVariant.rawValue,
                                pipelineConfig: pipelineConfig), to: fileURL)
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
