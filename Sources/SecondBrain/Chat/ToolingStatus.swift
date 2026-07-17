// ToolingStatus.swift — чистая логика индикации туллинга (задача 27).
//
// Здесь НЕТ SwiftUI: модели чипов источников инструментов над полем ввода,
// состояние репозитория проекта и шаги мастера «Ассистент проекта» — чистые
// билдеры, покрытые тестами (ToolingUxTests). View-слой (ChatToolingViews)
// только рисует эти структуры.

import Foundation

// MARK: - Состояние репозитория проекта

/// Состояние выбранного репозитория проекта — для чипа «Проект» и мастера.
enum ProjectRepoState: Equatable {
    /// Путь пуст — инструменты не настроены.
    case notConfigured
    /// Путь задан, но папки на диске нет (переименовали/удалили).
    case broken(path: String)
    case ready(path: String)

    /// Синхронная оценка: пустой путь / отсутствующая папка / папка есть.
    /// Проверка «это git-репозиторий?» осознанно НЕ здесь: она асинхронная
    /// (GitClient.isRepository) и живёт на вкладке настроек «Инструменты».
    static func evaluate(path: String,
                         fileManager: FileManager = .default) -> ProjectRepoState {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notConfigured }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .broken(path: trimmed)
        }
        return .ready(path: trimmed)
    }
}

// MARK: - Сводки источников инструментов (чипы)

/// Сводка одного источника инструментов чата — модель чипа над полем ввода.
struct ToolSourceSummary: Identifiable, Equatable {
    enum Kind: Equatable {
        case project
        case mcp(serverID: UUID)
    }

    /// Светофор чипа: ok — зелёный, unknown — серый (не проверялся),
    /// warning — оранжевый (репозиторий сломан / сервер не отвечает).
    enum Health: Equatable {
        case ok, unknown, warning
    }

    let kind: Kind
    let title: String
    /// Число инструментов; nil — неизвестно (сервер не проверялся/сломан).
    let count: Int?
    let state: Health
    /// Строка статуса для поповера чипа.
    let detail: String

    var id: String {
        switch kind {
        case .project: return "project"
        case .mcp(let serverID): return serverID.uuidString
        }
    }

    /// Собирает чипы текущего чата. Порядок: проект, затем MCP-серверы в
    /// порядке массива servers. Фильтр серверов тот же, что в меню
    /// инструментов: enabled глобально + включён в этом чате — «осиротевшие»
    /// serverID из старых конфигов чипов не дают.
    static func make(configuration: ChatConfiguration,
                     projectRepo: ProjectRepoState,
                     projectToolCount: Int,
                     servers: [MCPServer],
                     statuses: [UUID: MCPServerStatus]) -> [ToolSourceSummary] {
        var result: [ToolSourceSummary] = []

        if configuration.projectToolsEnabled {
            switch projectRepo {
            case .ready(let path):
                result.append(ToolSourceSummary(
                    kind: .project, title: "Проект", count: projectToolCount, state: .ok,
                    detail: "Встроенные git-инструменты (только чтение) · \(path)"))
            case .notConfigured:
                result.append(ToolSourceSummary(
                    kind: .project, title: "Проект", count: nil, state: .warning,
                    detail: "Репозиторий не выбран — инструменты не работают. Настройки → «Инструменты»."))
            case .broken(let path):
                result.append(ToolSourceSummary(
                    kind: .project, title: "Проект", count: nil, state: .warning,
                    detail: "Папка репозитория не найдена: \(path)"))
            }
        }

        for server in servers
        where server.enabled && configuration.enabledMCPServerIDs.contains(server.id) {
            let title = server.name.isEmpty ? "(без имени)" : server.name
            guard let status = statuses[server.id] else {
                result.append(ToolSourceSummary(
                    kind: .mcp(serverID: server.id), title: title, count: nil, state: .unknown,
                    detail: "Не проверялся: «Тест» в настройках или первый вопрос с инструментами."))
                continue
            }
            if status.connected {
                result.append(ToolSourceSummary(
                    kind: .mcp(serverID: server.id), title: title,
                    count: status.toolCount, state: .ok,
                    detail: "Подключён · инструментов: \(status.toolCount)"))
            } else {
                result.append(ToolSourceSummary(
                    kind: .mcp(serverID: server.id), title: title, count: nil, state: .warning,
                    detail: status.error ?? "Сервер не отвечает"))
            }
        }
        return result
    }
}

// MARK: - Чип состояния базы знаний (RAG)

/// Сводка состояния RAG для чипа «База» (задачи 28, 31). Отвечает на «почему
/// агент не использует базу» и показывает ВЫБРАННЫЙ источник знаний чата —
/// vault или репозиторий проекта (единое место, миры не смешиваются).
struct RagChipSummary: Equatable {
    enum State: Equatable {
        /// Индекс построен, эмбеддер доступен, теги совпадают.
        case ready(chunks: Int)
        /// Идёт индексация (fraction 0…1; nil — доля неизвестна).
        case indexing(fraction: Double?)
        /// Нет провайдера эмбеддингов — RAG невозможен.
        case noEmbedder
        /// Индекс пуст (vault: нужна индексация; проект: построится сам).
        case empty
        /// Индекс построен другой моделью — нужна полная переиндексация (vault).
        case needsReindex
        /// Источник «Проект», но репозиторий не выбран.
        case repoMissing
    }

    let source: KnowledgeSource
    let state: State
    let title: String
    let detail: String
    let health: ToolSourceSummary.Health

    /// nil — тумблер «По базе» выключен, чипа нет.
    /// Vault-приоритет: индексация → нет эмбеддера → смена модели → пусто → готов.
    /// Проект: нет репо → нет эмбеддера → пусто (построится сам) → готов.
    static func make(ragEnabled: Bool,
                     source: KnowledgeSource,
                     embedderAvailable: Bool,
                     chunkCount: Int,
                     indexTag: String?,
                     currentTag: String?,
                     needsFullReindex: Bool,
                     isIndexing: Bool,
                     progressFraction: Double?,
                     projectRepo: ProjectRepoState,
                     docsChunks: Int?) -> RagChipSummary? {
        guard ragEnabled else { return nil }

        let noEmbedderChip = RagChipSummary(
            source: source, state: .noEmbedder, title: chipTitle(source),
            detail: "Нет модели эмбеддингов — установите nomic-embed-text во вкладке «Локальные модели» или добавьте ключ OpenAI/Gemini.",
            health: .warning)

        switch source {
        case .project:
            guard case .ready = projectRepo else {
                return RagChipSummary(
                    source: source, state: .repoMissing, title: chipTitle(source),
                    detail: "Репозиторий проекта не выбран — Настройки → «Инструменты».",
                    health: .warning)
            }
            guard embedderAvailable else { return noEmbedderChip }
            guard let docsChunks, docsChunks > 0 else {
                // Индекс доков строится лениво при первом вопросе — не ошибка.
                return RagChipSummary(
                    source: source, state: .empty, title: chipTitle(source),
                    detail: "Индекс документации построится при первом вопросе (README + docs репозитория).",
                    health: .unknown)
            }
            return RagChipSummary(
                source: source, state: .ready(chunks: docsChunks),
                title: "\(chipTitle(source)) · \(docsChunks)",
                detail: "Поиск по документации репозитория готов · чанков: \(docsChunks)",
                health: .ok)

        case .vault:
            if isIndexing {
                return RagChipSummary(source: source,
                                      state: .indexing(fraction: progressFraction),
                                      title: chipTitle(source),
                                      detail: "Идёт индексация vault…",
                                      health: .unknown)
            }
            guard embedderAvailable else { return noEmbedderChip }
            let tagMismatch = indexTag != nil && currentTag != nil && indexTag != currentTag
            if needsFullReindex || tagMismatch {
                return RagChipSummary(
                    source: source, state: .needsReindex, title: chipTitle(source),
                    detail: "Модель эмбеддинга изменилась — векторы несовместимы, нужна полная переиндексация.",
                    health: .warning)
            }
            guard chunkCount > 0 else {
                return RagChipSummary(
                    source: source, state: .empty, title: chipTitle(source),
                    detail: "Индекс пуст — проиндексируйте vault, чтобы отвечать по заметкам.",
                    health: .warning)
            }
            return RagChipSummary(source: source,
                                  state: .ready(chunks: chunkCount),
                                  title: "\(chipTitle(source)) · \(chunkCount)",
                                  detail: "Поиск по vault готов · чанков: \(chunkCount)",
                                  health: .ok)
        }
    }

    private static func chipTitle(_ source: KnowledgeSource) -> String {
        switch source {
        case .vault: return "База: Vault"
        case .project: return "База: Проект"
        }
    }
}

// MARK: - Мастер «Ассистент проекта»

/// Шаги мастера в пустом чате; все done — конфигурация готова к /help.
struct ProjectWizardState: Equatable {
    struct Step: Identifiable, Equatable {
        enum Kind: String {
            case repo, model, tools
        }

        let kind: Kind
        let title: String
        let done: Bool
        var id: String { kind.rawValue }
    }

    let steps: [Step]

    var isComplete: Bool { steps.allSatisfy(\.done) }
    /// Шаг «Включить инструменты» имеет смысл только при выбранном репозитории.
    var repoDone: Bool { steps.first { $0.kind == .repo }?.done ?? false }

    static func make(repoConfigured: Bool,
                     providerAvailable: Bool,
                     toolsEnabledInChat: Bool) -> ProjectWizardState {
        ProjectWizardState(steps: [
            Step(kind: .repo, title: "Репозиторий проекта выбран", done: repoConfigured),
            Step(kind: .model, title: "Модель доступна (ключ или локальный рантайм)",
                 done: providerAvailable),
            Step(kind: .tools, title: "Инструменты включены в этом чате",
                 done: toolsEnabledInChat)
        ])
    }
}
