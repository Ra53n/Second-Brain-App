// TuneSelection.swift — чистое ядро (P1) выбора адаптера/базы мульти-модельных
// тюнов одного датасета (задача 92): какой каталог адаптера у прогона на модели X,
// какой прогон поднимать под чат `.tuned`, когда легаси-путь ещё уместен.

import Foundation

enum TuneSelection {
    /// Единая подпись локальной цели эскалации — её показывают и пикер
    /// (`FineTuneChatViews`), и `displayName` резолвнутого провайдера (`AppModel`).
    static func localTunedDisplayName(model: String) -> String {
        "Тюн \(adapterDirName(model: model)) (локально)"
    }

    /// Последний компонент id модели, санитизированный под имя каталога. Модель
    /// приходит из TextField (FineTuneRunViews) — опечатка/копипаста возможна.
    /// Вырожденные входы (пусто, только слэши, `.`/`..`/`../..`) → "default": пустой
    /// слаг дал бы коллизию с легаси `adapters/`, слаг из точек — path traversal
    /// (`adapters/..` резолвится в корень датасета, куда train.py не должен писать).
    static func adapterDirName(model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "default" }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard let slug = components.last.map(String.init), !slug.isEmpty,
              slug.contains(where: { $0 != "." }) else { return "default" }
        return slug
    }

    /// Каталог адаптера нового прогона, относительно workdir (совместим с
    /// `--adapter-dir` train.py: `os.path.join(root, "adapters/<slug>")`).
    static func adapterDir(model: String) -> String {
        "adapters/\(adapterDirName(model: model))"
    }

    /// Последний по времени старта завершённый прогон этого workdir на этой базе —
    /// пара «база + её адаптер» для чата `.tuned`.
    static func selectTunedRun(runs: [FineTuneRun], workdir: String, baseModel: String) -> FineTuneRun? {
        runs
            .filter { $0.workdir == workdir && $0.model == baseModel && $0.status == .finished }
            .max { $0.startedAt < $1.startedAt }
    }

    /// Базы для пикера чата: дефолты (3B, 7B) + distinct-модели завершённых прогонов
    /// этого workdir, без дублей, порядок стабильный (дефолты первыми).
    static func chatBaseModels(runs: [FineTuneRun], workdir: String, defaults: [String]) -> [String] {
        var seen = Set(defaults)
        var result = defaults
        for run in runs where run.workdir == workdir && run.status == .finished {
            guard seen.insert(run.model).inserted else { continue }
            result.append(run.model)
        }
        return result
    }

    /// Легаси-путь (`adapters/adapters.safetensors` без per-model подкаталога) уместен,
    /// только когда у workdir вообще нет завершённых прогонов (адаптер оставлен ДО
    /// задачи 92) и запрошена дефолтная 7B — иначе отсутствие тюна нужной базы обязано
    /// быть ошибкой, а не тихой подменой чужим (3B/7B) адаптером.
    static func legacyAdapterFallback(runs: [FineTuneRun], workdir: String, baseModel: String) -> Bool {
        let hasAnyFinished = runs.contains { $0.workdir == workdir && $0.status == .finished }
        return !hasAnyFinished && baseModel == MlxServerConfig.defaultModel
    }
}
