// FineTuneStore.swift — персистентность прогонов тюнинга (P2, образец PipelineStore).
//
// finetune-runs.json в Application Support, плоско, без <vault-id>: датасеты и
// прогоны привязаны к репозиторию, не к vault пользователя (задача 81).

import Combine
import Foundation

/// Документ finetune-runs.json.
struct FineTuneDocument: Codable {
    var runs: [FineTuneRun] = []
    /// Результат последней валидации, ключ — workdir датасета.
    var validations: [String: FineTuneValidationRecord] = [:]
    /// Настройка `--min-assistant` на датасет (задача 82), ключ — workdir.
    var minAssistantOverrides: [String: Int] = [:]

    init(runs: [FineTuneRun] = [], validations: [String: FineTuneValidationRecord] = [:],
         minAssistantOverrides: [String: Int] = [:]) {
        self.runs = runs
        self.validations = validations
        self.minAssistantOverrides = minAssistantOverrides
    }

    enum CodingKeys: String, CodingKey { case runs, validations, minAssistantOverrides }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent([FineTuneRun].self, forKey: .runs) ?? []
        validations = try c.decodeIfPresent([String: FineTuneValidationRecord].self, forKey: .validations) ?? [:]
        minAssistantOverrides = try c.decodeIfPresent([String: Int].self, forKey: .minAssistantOverrides) ?? [:]
    }
}

/// Персистентная копия результата валидации датасета (P2) — снисходительный декодер
/// на случай будущего дрейфа формата, как и весь остальной документ.
struct FineTuneValidationRecord: Codable, Equatable {
    struct Issue: Codable, Equatable {
        var file: String?
        var line: Int?
        var text: String

        init(file: String?, line: Int?, text: String) {
            self.file = file
            self.line = line
            self.text = text
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.decodeIfPresent(String.self, forKey: .file)
            line = try c.decodeIfPresent(Int.self, forKey: .line)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        }
    }

    var isValid: Bool
    var notes: [String]
    var issues: [Issue]
    var checkedAt: Date

    init(isValid: Bool, notes: [String], issues: [Issue], checkedAt: Date = Date()) {
        self.isValid = isValid
        self.notes = notes
        self.issues = issues
        self.checkedAt = checkedAt
    }

    init(result: FineTuneValidationParser.Result, checkedAt: Date = Date()) {
        isValid = result.isValid
        notes = result.notes
        issues = result.issues.map { Issue(file: $0.file, line: $0.line, text: $0.text) }
        self.checkedAt = checkedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isValid = try c.decodeIfPresent(Bool.self, forKey: .isValid) ?? false
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        checkedAt = try c.decodeIfPresent(Date.self, forKey: .checkedAt) ?? Date()
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

/// Активный сегмент средней колонки раздела «Тюнинг» (runtime, не персистится,
/// задача 82). Живёт в сторе, а не в `@State` `FineTunePane`: `FineTuneDetailView` —
/// отдельный экземпляр View (middle/detail колонки NavigationSplitView), и для
/// «Baseline»/«Критерии» ему нужно знать активный сегмент — при той же выбранной
/// записи (`.dataset(id)`) он показывает разный контент в зависимости от сегмента.
enum FineTuneScreen: String, CaseIterable, Identifiable {
    case datasets = "Датасеты"
    case runs = "Прогоны"
    case baseline = "Baseline"
    case criteria = "Критерии"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .datasets: return "tray.full"
        case .runs: return "chart.xyaxis.line"
        case .baseline: return "checklist"
        case .criteria: return "list.bullet.clipboard"
        }
    }
}

/// Владелец истории прогонов тюнинга в рантайме.
@MainActor
final class FineTuneStore: ObservableObject {
    @Published private(set) var runs: [FineTuneRun] = []
    @Published var selection: FineTuneSelection?
    @Published var screen: FineTuneScreen = .datasets
    @Published private(set) var validations: [String: FineTuneValidationRecord] = [:]
    @Published private(set) var minAssistantOverrides: [String: Int] = [:]

    /// Кап истории: прогоны — операционный лог, старое не нужно.
    static let runsCap = 50
    /// `validate.py` по умолчанию требует ≥120 символов у assistant.
    static let defaultMinAssistant = 120
    /// Датасет со своим `system_prompt.txt` рядом (например, диктовка) обычно снят
    /// под короткие ответы (finetune/README.md) — общий дефолт 120 валил бы там
    /// каждую строку ещё до первой настройки пользователем. Признак — наличие
    /// файла, не имя каталога: переименование workdir раньше тихо роняло порог.
    private static let ownSystemPromptMinAssistant = 30

    private let url: URL
    private var saveCancellable: AnyCancellable?

    init(url: URL = FineTunePersistence.defaultURL) {
        self.url = url
        let document = FineTunePersistence.loadDocument(from: url)
        runs = document.runs
        validations = document.validations
        minAssistantOverrides = document.minAssistantOverrides
        normalize()

        saveCancellable = Publishers.CombineLatest3($runs, $validations, $minAssistantOverrides)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [url] runs, validations, minAssistantOverrides in
                let document = FineTuneStore.makeDocument(runs: runs, validations: validations,
                                                          minAssistantOverrides: minAssistantOverrides)
                DispatchQueue.global(qos: .utility).async {
                    FineTunePersistence.save(document, to: url)
                }
            }
    }

    /// Единственное место сборки документа: и `persistNow()`, и дебаунс-автосохранение
    /// выше зовут именно эту функцию — раньше дебаунс-подписка строила документ вручную
    /// только из `runs`, что на диске тихо стирало `validations`/`minAssistantOverrides`
    /// (регрессия задачи 82, покрыта `FineTuneStoreTests.testMakeDocumentCombinesAllThreeFields`).
    static func makeDocument(runs: [FineTuneRun], validations: [String: FineTuneValidationRecord],
                            minAssistantOverrides: [String: Int]) -> FineTuneDocument {
        FineTuneDocument(runs: runs, validations: validations, minAssistantOverrides: minAssistantOverrides)
    }

    /// Синхронная запись без debounce — вокруг стартов/финалов прогонов и на выходе приложения.
    func persistNow() {
        FineTunePersistence.save(FineTuneStore.makeDocument(runs: runs, validations: validations,
                                                            minAssistantOverrides: minAssistantOverrides), to: url)
    }

    func setValidation(_ record: FineTuneValidationRecord, workdir: String) {
        validations[workdir] = record
        persistNow()
    }

    func validationRecord(workdir: String) -> FineTuneValidationRecord? {
        validations[workdir]
    }

    func minAssistant(workdir: String, hasOwnSystemPrompt: Bool = false) -> Int {
        minAssistantOverrides[workdir] ?? (hasOwnSystemPrompt ? Self.ownSystemPromptMinAssistant : Self.defaultMinAssistant)
    }

    /// Без `persistNow()`: щёлкают Stepper часто, синхронная запись на каждый клик
    /// лишняя при уже работающем дебаунс-автосохранении выше.
    func setMinAssistant(_ value: Int, workdir: String) {
        minAssistantOverrides[workdir] = value
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

    /// «Baseline»/«Критерии» показывают ровно один датасет — без выбора первый
    /// заход требовал бы лишнего клика (список датасетов через AX ненадёжен, задача
    /// 82). Не трогает другие сегменты и не переключает уже валидный выбор.
    func selectFirstDatasetIfNeeded(datasets: [FineTuneDataset]) {
        guard screen == .baseline || screen == .criteria else { return }
        if case .dataset(let id) = selection, datasets.contains(where: { $0.id == id }) { return }
        guard let first = datasets.first else { return }
        selection = .dataset(first.id)
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
