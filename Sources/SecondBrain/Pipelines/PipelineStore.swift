// PipelineStore.swift — персистентность пайплайнов (задача 36, паттерн
// ChatStore/MeetingStore).
//
// Два файла в Application Support:
//  - pipelines.json — конфиги + runtime-состояние PR-watch (единым документом:
//    состояние маленькое, а отдельный файл ради Set<Int> не нужен);
//  - pipeline-runs.json — история прогонов, кап PipelineStore.runsCap записей
//    (старейшие вытесняются; история — лог, не источник конфигурации).
// Правила (CONVENTIONS.md): атомарная запись, битый файл → карантин
// *.corrupt.json, автосейв с debounce 300 мс, persistNow() в ключевых точках,
// normalize() на старте: running-прогоны → error «Прерван рестартом» (живых
// Task после рестарта нет, а прогон пайплайна — не возобновляемая сущность,
// в отличие от paused у встреч/чатов).

import Combine
import Foundation

/// Документ pipelines.json: конфиги + состояние PR-watch.
struct PipelinesDocument: Codable {
    var pipelines: [PipelineConfig] = []
    var prWatchState: [UUID: PRWatchState] = [:]

    init(pipelines: [PipelineConfig] = [], prWatchState: [UUID: PRWatchState] = [:]) {
        self.pipelines = pipelines
        self.prWatchState = prWatchState
    }

    enum CodingKeys: String, CodingKey { case pipelines, prWatchState }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pipelines = try c.decodeIfPresent([PipelineConfig].self, forKey: .pipelines) ?? []
        prWatchState = try c.decodeIfPresent([UUID: PRWatchState].self, forKey: .prWatchState)
            ?? [:]
    }
}

/// Чтение/запись файлов пайплайнов (чистые функции, URL инжектируется в тестах).
enum PipelinePersistence {
    static var defaultPipelinesURL: URL {
        Config.appSupportDirectory.appendingPathComponent("pipelines.json")
    }

    static var defaultRunsURL: URL {
        Config.appSupportDirectory.appendingPathComponent("pipeline-runs.json")
    }

    static func loadDocument(from url: URL) -> PipelinesDocument {
        decodeOrQuarantine(url) ?? PipelinesDocument()
    }

    static func loadRuns(from url: URL) -> [PipelineRun] {
        decodeOrQuarantine(url) ?? []
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Битый файл — в карантин *.corrupt.json, стартуем с пустого состояния.
    private static func decodeOrQuarantine<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }
}

/// Владелец конфигов и истории прогонов в рантайме.
@MainActor
final class PipelineStore: ObservableObject {
    @Published var pipelines: [PipelineConfig] = []
    @Published private(set) var runs: [PipelineRun] = []
    @Published var prWatchState: [UUID: PRWatchState] = [:]
    /// Выбранный в разделе пайплайн (runtime, не персистится) — общий для
    /// списка (средняя колонка) и detail-редактора.
    @Published var selectedPipelineID: UUID?

    /// Кап истории: прогоны — операционный лог, старое не нужно.
    static let runsCap = 200

    private let pipelinesURL: URL
    private let runsURL: URL
    private var saveCancellables: Set<AnyCancellable> = []

    init(pipelinesURL: URL = PipelinePersistence.defaultPipelinesURL,
         runsURL: URL = PipelinePersistence.defaultRunsURL) {
        self.pipelinesURL = pipelinesURL
        self.runsURL = runsURL
        let document = PipelinePersistence.loadDocument(from: pipelinesURL)
        pipelines = document.pipelines
        prWatchState = document.prWatchState
        runs = PipelinePersistence.loadRuns(from: runsURL)
        normalize()

        // Автосохранение с debounce — правки формы редактора не молотят диск.
        $pipelines.combineLatest($prWatchState)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [pipelinesURL] pipelines, state in
                DispatchQueue.global(qos: .utility).async {
                    PipelinePersistence.save(
                        PipelinesDocument(pipelines: pipelines, prWatchState: state),
                        to: pipelinesURL)
                }
            }
            .store(in: &saveCancellables)
        $runs
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [runsURL] runs in
                DispatchQueue.global(qos: .utility).async {
                    PipelinePersistence.save(runs, to: runsURL)
                }
            }
            .store(in: &saveCancellables)
    }

    /// Синхронная запись без debounce — вокруг стартов/финалов прогонов и на
    /// выходе приложения (crash-safety).
    func persistNow() {
        PipelinePersistence.save(
            PipelinesDocument(pipelines: pipelines, prWatchState: prWatchState),
            to: pipelinesURL)
        PipelinePersistence.save(runs, to: runsURL)
    }

    // MARK: - Пайплайны (CRUD)

    func pipeline(id: UUID) -> PipelineConfig? {
        pipelines.first { $0.id == id }
    }

    func add(_ pipeline: PipelineConfig) {
        pipelines.insert(pipeline, at: 0)
        persistNow()
    }

    /// Мутация конфига на месте. Возвращает false, если пайплайн удалён.
    @discardableResult
    func mutate(id: UUID, _ change: (inout PipelineConfig) -> Void) -> Bool {
        guard let index = pipelines.firstIndex(where: { $0.id == id }) else { return false }
        change(&pipelines[index])
        return true
    }

    /// Удаление пайплайна каскадно чистит его прогоны и состояние PR-watch —
    /// осиротевшие записи бессмысленны.
    func remove(id: UUID) {
        pipelines.removeAll { $0.id == id }
        runs.removeAll { $0.pipelineID == id }
        prWatchState[id] = nil
        persistNow()
    }

    // MARK: - Прогоны

    /// Новые прогоны — в начало (история показывается свежими вверх), хвост
    /// за капом отбрасывается.
    func appendRun(_ run: PipelineRun) {
        runs.insert(run, at: 0)
        if runs.count > Self.runsCap {
            runs.removeLast(runs.count - Self.runsCap)
        }
        persistNow()
    }

    @discardableResult
    func updateRun(id: UUID, _ change: (inout PipelineRun) -> Void) -> Bool {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return false }
        change(&runs[index])
        persistNow()
        return true
    }

    /// Последний прогон пайплайна (runs упорядочены свежими вверх).
    func latestRun(pipelineID: UUID) -> PipelineRun? {
        runs.first { $0.pipelineID == pipelineID }
    }

    // MARK: - Нормализация

    /// Зависшие running после рестарта → error: живых Task нет, а прогон
    /// пайплайна не возобновляем (следующий слот запустит новый).
    private func normalize() {
        var changed = false
        for index in runs.indices where runs[index].status == .running {
            runs[index].status = .error
            runs[index].errorText = "Прерван рестартом приложения."
            runs[index].finishedAt = runs[index].finishedAt ?? runs[index].startedAt
            changed = true
        }
        if changed { persistNow() }
    }
}
