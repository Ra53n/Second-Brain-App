// FineTuneStore.swift — персистентность прогонов тюнинга (P2, образец PipelineStore).
//
// finetune-runs.json в Application Support, плоско, без <vault-id>: датасеты и
// прогоны привязаны к репозиторию, не к vault пользователя (задача 81).

import Combine
import Foundation

/// Документ finetune-runs.json.
struct FineTuneDocument: Codable {
    var runs: [FineTuneRun] = []

    init(runs: [FineTuneRun] = []) {
        self.runs = runs
    }

    enum CodingKeys: String, CodingKey { case runs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent([FineTuneRun].self, forKey: .runs) ?? []
    }
}

/// Чтение/запись finetune-runs.json (чистые функции, URL инжектируется в тестах).
enum FineTunePersistence {
    static var defaultURL: URL {
        Config.appSupportDirectory.appendingPathComponent("finetune-runs.json")
    }

    static func loadDocument(from url: URL) -> FineTuneDocument {
        decodeOrQuarantine(url) ?? FineTuneDocument()
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

/// Выбор в разделе «Тюнинг» (runtime, не персистится).
enum FineTuneSelection: Hashable {
    case dataset(String)
    case run(UUID)
}

/// Владелец истории прогонов тюнинга в рантайме.
@MainActor
final class FineTuneStore: ObservableObject {
    @Published private(set) var runs: [FineTuneRun] = []
    @Published var selection: FineTuneSelection?

    /// Кап истории: прогоны — операционный лог, старое не нужно.
    static let runsCap = 50

    private let url: URL
    private var saveCancellable: AnyCancellable?

    init(url: URL = FineTunePersistence.defaultURL) {
        self.url = url
        runs = FineTunePersistence.loadDocument(from: url).runs
        normalize()

        saveCancellable = $runs
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [url] runs in
                DispatchQueue.global(qos: .utility).async {
                    FineTunePersistence.save(FineTuneDocument(runs: runs), to: url)
                }
            }
    }

    /// Синхронная запись без debounce — вокруг стартов/финалов прогонов и на выходе приложения.
    func persistNow() {
        FineTunePersistence.save(FineTuneDocument(runs: runs), to: url)
    }

    /// Новые прогоны — в начало (история показывается свежими вверх).
    func appendRun(_ run: FineTuneRun) {
        runs.insert(run, at: 0)
        if runs.count > Self.runsCap {
            runs.removeLast(runs.count - Self.runsCap)
        }
        persistNow()
    }

    @discardableResult
    func updateRun(id: UUID, _ change: (inout FineTuneRun) -> Void) -> Bool {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return false }
        change(&runs[index])
        persistNow()
        return true
    }

    /// Последний прогон датасета (runs упорядочены свежими вверх).
    func latestRun(workdir: String) -> FineTuneRun? {
        runs.first { $0.workdir == workdir }
    }

    /// Зависшие running после рестарта: мёртвый или отсутствующий pid → interrupted (P5).
    private func normalize() {
        var changed = false
        for index in runs.indices where runs[index].status == .running {
            // pid ≤ 1 никогда не наш прогон (0 — недописанный run.json, 1 — launchd);
            // kill(0,0) отвечает 0 (группа приложения жива), что ложно выглядело бы
            // как «прогон идёт» и блокировало бы старт/диалог выхода навсегда.
            let alive = runs[index].pid.map { $0 > 1 && kill($0, 0) == 0 } ?? false
            if !alive {
                runs[index].status = .interrupted
                runs[index].finishedAt = runs[index].finishedAt ?? Date()
                changed = true
            }
        }
        if changed { persistNow() }
    }
}
