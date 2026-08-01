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
    /// Настройка `--count` для `baseline.py` на датасет (задача 83), ключ — workdir.
    var baselineCountOverrides: [String: Int] = [:]
    /// Настройка `--max-reuse` на датасет (задача 84), ключ — workdir.
    var maxReuseOverrides: [String: Int] = [:]

    init(runs: [FineTuneRun] = [], validations: [String: FineTuneValidationRecord] = [:],
         minAssistantOverrides: [String: Int] = [:], baselineCountOverrides: [String: Int] = [:],
         maxReuseOverrides: [String: Int] = [:]) {
        self.runs = runs
        self.validations = validations
        self.minAssistantOverrides = minAssistantOverrides
        self.baselineCountOverrides = baselineCountOverrides
        self.maxReuseOverrides = maxReuseOverrides
    }

    enum CodingKeys: String, CodingKey {
        case runs, validations, minAssistantOverrides, baselineCountOverrides, maxReuseOverrides
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent([FineTuneRun].self, forKey: .runs) ?? []
        validations = try c.decodeIfPresent([String: FineTuneValidationRecord].self, forKey: .validations) ?? [:]
        minAssistantOverrides = try c.decodeIfPresent([String: Int].self, forKey: .minAssistantOverrides) ?? [:]
        baselineCountOverrides = try c.decodeIfPresent([String: Int].self, forKey: .baselineCountOverrides) ?? [:]
        maxReuseOverrides = try c.decodeIfPresent([String: Int].self, forKey: .maxReuseOverrides) ?? [:]
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
}

/// Владелец истории прогонов тюнинга в рантайме.
@MainActor
final class FineTuneStore: ObservableObject {
    @Published private(set) var runs: [FineTuneRun] = []
    @Published var selection: FineTuneSelection?
    /// Активная вкладка выбранного датасета (runtime, не персистится, задача 83).
    @Published var datasetTab: FineTuneDatasetTab = .overview
    /// Прогон, открытый на вкладке «Прогоны» (runtime, не персистится).
    @Published var selectedRunID: UUID?
    @Published private(set) var validations: [String: FineTuneValidationRecord] = [:]
    @Published private(set) var minAssistantOverrides: [String: Int] = [:]
    @Published private(set) var baselineCountOverrides: [String: Int] = [:]
    @Published private(set) var maxReuseOverrides: [String: Int] = [:]

    /// Кап истории: прогоны — операционный лог, старое не нужно.
    static let runsCap = 50
    /// `validate.py` по умолчанию требует ≥120 символов у assistant.
    static let defaultMinAssistant = 120
    /// `validate.py` считает дублями повтор одного текста assistant чаще трёх раз.
    /// Для генеративного датасета это верно, для классификации — нет: там повтор
    /// метки норма, и без своего порога такой датасет валиден быть не может.
    static let defaultMaxReuse = 3
    /// Значение для датасета классификации: заведомо больше любого разумного числа
    /// примеров, то есть проверка на дубли перестаёт срабатывать. Осмысленного
    /// «правильного» порога здесь нет — есть решение «повтор метки не дубль»,
    /// поэтому в UI это переключатель, а не число (Stepper до сотен — не контрол).
    static let classificationMaxReuse = 1_000_000
    /// Ответ классификатора короткий по своей природе: `{"action_items": []}` — 20
    /// символов. Оба порога валидатора ломаются об один и тот же класс датасетов,
    /// поэтому переключатель один и опускает их вместе: закрыть только повторы
    /// и оставить длину — оставить валидацию красной ровно так же.
    static let classificationMinAssistant = 20
    /// Датасет со своим `system_prompt.txt` рядом (например, диктовка) обычно снят
    /// под короткие ответы (finetune/README.md) — общий дефолт 120 валил бы там
    /// каждую строку ещё до первой настройки пользователем. Признак — наличие
    /// файла, не имя каталога: переименование workdir раньше тихо роняло порог.
    static let ownSystemPromptMinAssistant = 30

    private let url: URL
    private var saveCancellable: AnyCancellable?

    init(url: URL = FineTunePersistence.defaultURL) {
        self.url = url
        let document = FineTunePersistence.loadDocument(from: url)
        runs = document.runs
        validations = document.validations
        minAssistantOverrides = document.minAssistantOverrides
        baselineCountOverrides = document.baselineCountOverrides
        maxReuseOverrides = document.maxReuseOverrides
        normalize()

        // CombineLatest4 исчерпан пятым полем, поэтому пары вложены: важно, что точка
        // сборки документа осталась одна (`makeDocument`) — см. регрессию задачи 82.
        saveCancellable = Publishers.CombineLatest4($runs, $validations, $minAssistantOverrides, $baselineCountOverrides)
            .combineLatest($maxReuseOverrides)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [url] combined, maxReuseOverrides in
                let (runs, validations, minAssistantOverrides, baselineCountOverrides) = combined
                let document = FineTuneStore.makeDocument(runs: runs, validations: validations,
                                                          minAssistantOverrides: minAssistantOverrides,
                                                          baselineCountOverrides: baselineCountOverrides,
                                                          maxReuseOverrides: maxReuseOverrides)
                DispatchQueue.global(qos: .utility).async {
                    FineTunePersistence.save(document, to: url)
                }
            }
    }

    /// Единственное место сборки документа: и `persistNow()`, и дебаунс-автосохранение
    /// выше зовут именно эту функцию — раньше дебаунс-подписка строила документ вручную
    /// только из `runs`, что на диске тихо стирало `validations`/`minAssistantOverrides`
    /// (регрессия задачи 82, покрыта `FineTuneStoreTests.testMakeDocumentCombinesAllFields`).
    static func makeDocument(runs: [FineTuneRun], validations: [String: FineTuneValidationRecord],
                            minAssistantOverrides: [String: Int],
                            baselineCountOverrides: [String: Int],
                            maxReuseOverrides: [String: Int]) -> FineTuneDocument {
        FineTuneDocument(runs: runs, validations: validations, minAssistantOverrides: minAssistantOverrides,
                         baselineCountOverrides: baselineCountOverrides,
                         maxReuseOverrides: maxReuseOverrides)
    }

    /// Синхронная запись без debounce — вокруг стартов/финалов прогонов и на выходе приложения.
    func persistNow() {
        FineTunePersistence.save(FineTuneStore.makeDocument(runs: runs, validations: validations,
                                                            minAssistantOverrides: minAssistantOverrides,
                                                            baselineCountOverrides: baselineCountOverrides,
                                                            maxReuseOverrides: maxReuseOverrides), to: url)
    }

    func setValidation(_ record: FineTuneValidationRecord, workdir: String) {
        validations[workdir] = record
        persistNow()
    }

    func validationRecord(workdir: String) -> FineTuneValidationRecord? {
        validations[workdir]
    }

    func minAssistant(workdir: String, hasOwnSystemPrompt: Bool = false) -> Int {
        if let explicit = minAssistantOverrides[workdir] { return explicit }
        if allowsRepeatedAnswers(workdir: workdir) { return Self.classificationMinAssistant }
        return hasOwnSystemPrompt ? Self.ownSystemPromptMinAssistant : Self.defaultMinAssistant
    }

    /// Без `persistNow()`: щёлкают Stepper часто, синхронная запись на каждый клик
    /// лишняя при уже работающем дебаунс-автосохранении выше.
    func setMinAssistant(_ value: Int, workdir: String) {
        minAssistantOverrides[workdir] = value
    }

    /// Без `persistNow()` — тот же резон, что у `setMinAssistant`: Stepper щёлкают часто.
    func setBaselineCount(_ value: Int, workdir: String) {
        baselineCountOverrides[workdir] = value
    }

    func maxReuse(workdir: String) -> Int {
        maxReuseOverrides[workdir] ?? Self.defaultMaxReuse
    }

    /// Без `persistNow()` — тот же резон, что у `setMinAssistant`.
    func setMaxReuse(_ value: Int, workdir: String) {
        maxReuseOverrides[workdir] = value
    }

    func allowsRepeatedAnswers(workdir: String) -> Bool {
        maxReuse(workdir: workdir) > Self.defaultMaxReuse
    }

    func setAllowsRepeatedAnswers(_ allowed: Bool, workdir: String) {
        setMaxReuse(allowed ? Self.classificationMaxReuse : Self.defaultMaxReuse, workdir: workdir)
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

    /// Detail-экран существует только при выбранном датасете (список датасетов
    /// через AX ненадёжен, задача 82) — автовыбор первого происходит всегда, не
    /// только на части вкладок (задача 83). Не трогает уже валидный выбор.
    func selectFirstDatasetIfNeeded(datasets: [FineTuneDataset]) {
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
