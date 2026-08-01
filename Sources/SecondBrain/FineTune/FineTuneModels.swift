// FineTuneModels.swift — доменные типы раздела «Тюнинг» (задача 81).
//
// Контракт с CLI `finetune/train.py` — файлы, не stdout: `run.json` и
// `train.log`. Формат `run.json` уже дрейфовал (`val_batches` на диске 4
// против нынешнего дефолта -1, `learning_rate` — строка) — декодеры здесь
// снисходительны на каждое поле.

import Foundation

/// Один каталог-датасет (`<root>/data/{train,valid}.jsonl`).
struct FineTuneDataset: Identifiable, Equatable {
    /// Значение `--workdir` для CLI: "." для `finetune/data`, "dictation" для `finetune/dictation/data`.
    let id: String
    let title: String
    let workdir: String
    /// Каталог-владелец `data/` (сам `finetune/` для "." или его подкаталог).
    let rootURL: URL
    let dataURL: URL
    let trainCount: Int
    let validCount: Int
    let split: FineTuneSplitInfo?
    let systemPromptPath: String?
    /// Артефакты домашки задачи 82 (nil — файла/каталога нет).
    let baselineURL: URL?
    let criteriaURL: URL?
    /// Ответы тюна, снятые тем же `baseline.py --adapter` (задача 83, вкладка «Обзор»).
    let tunedURL: URL?

    /// `let`-свойство с дефолтом Swift исключил бы из мемберайз-инициализатора совсем —
    /// явный init нужен, чтобы старые вызовы без новых полей продолжали собираться.
    init(id: String, title: String, workdir: String, rootURL: URL, dataURL: URL, trainCount: Int,
         validCount: Int, split: FineTuneSplitInfo?, systemPromptPath: String?,
         baselineURL: URL? = nil, criteriaURL: URL? = nil, tunedURL: URL? = nil) {
        self.id = id
        self.title = title
        self.workdir = workdir
        self.rootURL = rootURL
        self.dataURL = dataURL
        self.trainCount = trainCount
        self.validCount = validCount
        self.split = split
        self.systemPromptPath = systemPromptPath
        self.baselineURL = baselineURL
        self.criteriaURL = criteriaURL
        self.tunedURL = tunedURL
    }
}

/// `split.json` — может отсутствовать (у `dictation` его нет).
struct FineTuneSplitInfo: Codable, Equatable {
    struct Counts: Codable, Equatable {
        var train: Int
        var valid: Int

        init(train: Int = 0, valid: Int = 0) {
            self.train = train
            self.valid = valid
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            train = try c.decodeIfPresent(Int.self, forKey: .train) ?? 0
            valid = try c.decodeIfPresent(Int.self, forKey: .valid) ?? 0
        }
    }

    var seed: Int?
    var evalFractionTarget: Double
    var evalPosts: [String]
    var counts: Counts

    enum CodingKeys: String, CodingKey {
        case seed
        case evalFractionTarget = "eval_fraction_target"
        case evalPosts = "eval_posts"
        case counts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seed = try c.decodeIfPresent(Int.self, forKey: .seed)
        evalFractionTarget = try c.decodeIfPresent(Double.self, forKey: .evalFractionTarget) ?? 0
        evalPosts = try c.decodeIfPresent([String].self, forKey: .evalPosts) ?? []
        counts = try c.decodeIfPresent(Counts.self, forKey: .counts) ?? Counts()
    }
}

/// Sidecar-метаданные строки датасета (`train.meta.jsonl`); связь с
/// `train.jsonl` — по индексу строки, ключа нет.
struct FineTuneExampleMeta: Codable, Equatable {
    var id: String
    var sourcePost: String
    var taskType: String
    var app: String?
    var handEdited: Bool?
    var timestamp: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sourcePost = "source_post"
        case taskType = "task_type"
        case app
        case handEdited = "hand_edited"
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        sourcePost = try c.decodeIfPresent(String.self, forKey: .sourcePost) ?? ""
        taskType = try c.decodeIfPresent(String.self, forKey: .taskType) ?? ""
        app = try c.decodeIfPresent(String.self, forKey: .app)
        handEdited = try c.decodeIfPresent(Bool.self, forKey: .handEdited)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
    }
}

/// Одна строка датасета (индекс = id) вместе с её sidecar-метаданными.
struct FineTuneExample: Identifiable, Equatable {
    let id: Int
    let system: String
    let user: String
    let assistant: String
    let meta: FineTuneExampleMeta?
}

/// Точка прогресса обучения, разобранная из строки лога mlx-lm.
struct FineTuneProgressPoint: Codable, Equatable {
    enum Kind: String, Codable {
        case train, val

        /// Незнакомый kind «из будущего» рушит именно эту точку (см.
        /// `FineTuneRun.decodeLenientPoints`) — подмена на `.train` тихо исказила
        /// бы график и выбор лучшего чекпоинта.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let kind = Kind(rawValue: raw) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "неизвестный kind точки: \(raw)"))
            }
            self = kind
        }
    }

    let iter: Int
    let kind: Kind
    let loss: Double
    let itPerSec: Double?
    let peakMemGB: Double?
}

/// Гиперпараметры `train.py start`; дефолты — те же, что в `DEFAULTS` python-клиента.
struct FineTuneHyperparameters: Codable, Equatable {
    var iters: Int
    var batchSize: Int
    var numLayers: Int
    var learningRate: String
    var maxSeqLength: Int
    var stepsPerReport: Int
    var stepsPerEval: Int
    var saveEvery: Int
    var valBatches: Int

    init(iters: Int = 300, batchSize: Int = 1, numLayers: Int = 8, learningRate: String = "1e-5",
         maxSeqLength: Int = 2048, stepsPerReport: Int = 10, stepsPerEval: Int = 50,
         saveEvery: Int = 50, valBatches: Int = -1) {
        self.iters = iters
        self.batchSize = batchSize
        self.numLayers = numLayers
        self.learningRate = learningRate
        self.maxSeqLength = maxSeqLength
        self.stepsPerReport = stepsPerReport
        self.stepsPerEval = stepsPerEval
        self.saveEvery = saveEvery
        self.valBatches = valBatches
    }

    enum CodingKeys: String, CodingKey {
        case iters
        case batchSize = "batch_size"
        case numLayers = "num_layers"
        case learningRate = "learning_rate"
        case maxSeqLength = "max_seq_length"
        case stepsPerReport = "steps_per_report"
        case stepsPerEval = "steps_per_eval"
        case saveEvery = "save_every"
        case valBatches = "val_batches"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iters = c.lenient(.iters, 300)
        batchSize = c.lenient(.batchSize, 1)
        numLayers = c.lenient(.numLayers, 8)
        learningRate = c.lenient(.learningRate, "1e-5")
        maxSeqLength = c.lenient(.maxSeqLength, 2048)
        stepsPerReport = c.lenient(.stepsPerReport, 10)
        stepsPerEval = c.lenient(.stepsPerEval, 50)
        saveEvery = c.lenient(.saveEvery, 50)
        valBatches = c.lenient(.valBatches, -1)
    }

    /// Флаги подкоманды `start`, в порядке `DEFAULTS` python-клиента.
    func cliArguments() -> [String] {
        [
            "--iters", String(iters),
            "--batch-size", String(batchSize),
            "--num-layers", String(numLayers),
            "--learning-rate", learningRate,
            "--max-seq-length", String(maxSeqLength),
            "--steps-per-report", String(stepsPerReport),
            "--steps-per-eval", String(stepsPerEval),
            "--save-every", String(saveEvery),
            "--val-batches", String(valBatches)
        ]
    }
}

/// Запись истории прогонов тюнинга (персистируется `FineTuneStore`).
struct FineTuneRun: Codable, Identifiable, Equatable {
    /// Незнакомое значение из будущих версий → .interrupted (безопаснее «висящего» running).
    enum Status: String, Codable {
        case running, finished, stopped, interrupted, failed

        init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = Status(rawValue: raw) ?? .interrupted
        }
    }

    var id = UUID()
    var workdir: String
    var datasetTitle: String
    var model: String
    var hyperparameters: FineTuneHyperparameters
    var pid: Int32?
    var startedAt: Date = Date()
    var finishedAt: Date?
    var status: Status = .running
    var points: [FineTuneProgressPoint] = []
    var bestIter: Int?
    var errorText: String?
    var logPath: String
    var adapterPath: String
    /// true — прогон обнаружен по живому pid в run.json, но записи о старте от
    /// нас в сторе не было (запущен из терминала). Такой прогон не регистрируется
    /// в BackgroundProcessRegistry и не гасится на выходе (инвариант №2).
    var isAdoptedExternally: Bool = false

    init(workdir: String, datasetTitle: String, model: String,
         hyperparameters: FineTuneHyperparameters, logPath: String, adapterPath: String) {
        self.workdir = workdir
        self.datasetTitle = datasetTitle
        self.model = model
        self.hyperparameters = hyperparameters
        self.logPath = logPath
        self.adapterPath = adapterPath
    }

    enum CodingKeys: String, CodingKey {
        case id, workdir, datasetTitle, model, hyperparameters, pid
        case startedAt, finishedAt, status, points, bestIter, errorText, logPath, adapterPath
        case isAdoptedExternally
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        workdir = try c.decodeIfPresent(String.self, forKey: .workdir) ?? "."
        datasetTitle = try c.decodeIfPresent(String.self, forKey: .datasetTitle) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        hyperparameters = try c.decodeIfPresent(FineTuneHyperparameters.self, forKey: .hyperparameters)
            ?? FineTuneHyperparameters()
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .interrupted
        points = FineTuneRun.decodeLenientPoints(c)
        bestIter = try c.decodeIfPresent(Int.self, forKey: .bestIter)
        errorText = try c.decodeIfPresent(String.self, forKey: .errorText)
        logPath = try c.decodeIfPresent(String.self, forKey: .logPath) ?? ""
        adapterPath = try c.decodeIfPresent(String.self, forKey: .adapterPath) ?? ""
        isAdoptedExternally = try c.decodeIfPresent(Bool.self, forKey: .isAdoptedExternally) ?? false
    }

    /// Точка с незнакомым `kind` выпадает целиком, остальные читаются как обычно —
    /// иначе одна точка «из будущего» роняла бы decode всего прогона (и весь
    /// finetune-runs.json, если бы ошибка ушла выше).
    private static func decodeLenientPoints(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) -> [FineTuneProgressPoint] {
        guard var nested = try? container.nestedUnkeyedContainer(forKey: .points) else { return [] }
        var result: [FineTuneProgressPoint] = []
        while !nested.isAtEnd {
            if let point = try? nested.decode(FineTuneProgressPoint.self) {
                result.append(point)
            } else {
                _ = try? nested.decode(FineTuneSkippedJSONValue.self)
            }
        }
        return result
    }
}

/// Заглушка для `decodeLenientPoints`: decode без чтения содержимого продвигает
/// курсор unkeyed-контейнера мимо элемента, который не разобрался как точка.
private struct FineTuneSkippedJSONValue: Decodable {
    init(from decoder: Decoder) throws { _ = try decoder.singleValueContainer() }
}

/// Снисходительный декодер `<workdir>/runs/run.json`, пишет его CLI-клиент.
struct FineTuneCLIRun: Codable, Equatable {
    var pid: Int
    var model: String
    var config: FineTuneHyperparameters
    var startedAt: Date
    var adapterPath: String
    var log: String

    enum CodingKeys: String, CodingKey {
        case pid, model, config
        case startedAt = "started_at"
        case adapterPath = "adapter_path"
        case log
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = c.lenient(.pid, -1)
        model = c.lenient(.model, "")
        config = c.lenient(.config, FineTuneHyperparameters())
        // Python пишет time.time() (эпоха с 1970) — Date по умолчанию декодирует
        // Double как timeIntervalSinceReferenceDate (с 2001), отсюда ручная конвертация.
        startedAt = Date(timeIntervalSince1970: c.lenient(.startedAt, 0))
        adapterPath = c.lenient(.adapterPath, "")
        log = c.lenient(.log, "")
    }
}

private extension KeyedDecodingContainer {
    /// Поле или дефолт, причём несовпадение типа равносильно отсутствию поля.
    /// `run.json` пишет внешний python-клиент, и его формат уже дрейфовал: одно
    /// поле «не того» типа не должно ронять разбор всей записи — иначе живой
    /// прогон выглядит как отсутствующий файл.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// Ошибки раздела «Тюнинг»; тексты пригодны для UI.
enum FineTuneError: LocalizedError, Equatable {
    case noRepoRoot
    case noFineTuneDirectory(String)
    case noEnvironment
    case alreadyRunning(pid: Int32)
    case startFailed(String)
    case datasetUnreadable(String)
    /// mlx не тянет тюн и снятие baseline одновременно (задача 83).
    case baselineRunning
    /// Генерация критериев (задача 83): ни одного chat-провайдера не настроено.
    case noChatProvider
    /// Модель ответила пустым текстом на генерацию критериев.
    case emptyCriteriaResponse
    /// `mlx_lm.server` не поднялся: нет python/модуля, порт занят чужим,
    /// не ответил за отведённое время (задача 85).
    case mlxServerUnavailable(String)
    /// Тюн или baseline активен — mlx не тянет их одновременно с чатом/батчем (задача 85).
    case tuneActive
    /// `.tuned` без `adapters/adapters.safetensors` — сначала прогнать тюн (задача 85).
    case adapterMissing
    /// `.tuned` без завершённого прогона ИМЕННО этой базы (задача 92, мульти-модельные
    /// тюны) — легаси-fallback на 7B здесь не подходит (адаптер другой базы, крах mlx).
    case tunedRunMissing(model: String)
    /// Мини-чат/батч (задача 85): `dataset()` не нашёл датасет «Встречи» — каталог
    /// ещё не просканирован (не путать с `.noRepoRoot` — репозиторий может быть задан).
    case datasetNotFound
    /// Батч-прогон (задача 85): `valid.jsonl` пуст или ни одна строка не разобралась
    /// как валидный пример — пустой отчёт молча затёр бы прежний артефакт (P6).
    case validSetEmpty(String)

    var errorDescription: String? {
        switch self {
        case .noRepoRoot:
            return "Путь к репозиторию не задан — укажите его в настройках проекта."
        case let .noFineTuneDirectory(path):
            return "Каталог тюнинга не найден: \(path)."
        case .noEnvironment:
            return FineTuneEnvironment.installHint
        case let .alreadyRunning(pid):
            return "Прогон уже идёт (pid \(pid)). Останови его или дождись конца."
        case let .startFailed(detail):
            return "Не удалось запустить тюн: \(detail)"
        case let .datasetUnreadable(path):
            return "Не удалось прочитать датасет: \(path)"
        case .baselineRunning:
            return "Идёт снятие baseline — дождитесь или отмените."
        case .noChatProvider:
            return "Нет доступного провайдера чата — настройте модель в Настройки → Модели."
        case .emptyCriteriaResponse:
            return "Модель вернула пустой ответ."
        case let .mlxServerUnavailable(detail):
            return "mlx-сервер недоступен: \(detail)"
        case .tuneActive:
            return "Идёт тюн или снятие baseline — чат и батч недоступны, дождитесь завершения."
        case .adapterMissing:
            return "Адаптер не найден — сначала прогоните тюн."
        case let .tunedRunMissing(model):
            return "Нет завершённого тюна для базы \(model) — прогоните тюн на этой базе или выберите другую."
        case .datasetNotFound:
            return "Датасет «Встречи» не найден — открой раздел «Тюнинг»."
        case let .validSetEmpty(path):
            return "valid.jsonl пуст или не содержит валидных примеров: \(path)"
        }
    }
}
