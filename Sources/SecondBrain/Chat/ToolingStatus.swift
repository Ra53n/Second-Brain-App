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
            // Задача 39: каталог может быть переопределён для этого чата,
            // режим разрешений — в подписи (видно без клика).
            let isOverride = !(configuration.projectRootPath ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let title = isOverride ? "Проект (чат)" : "Проект"
            let mode = " · режим: \(configuration.permissionMode.label)"
            switch projectRepo {
            case .ready(let path):
                result.append(ToolSourceSummary(
                    kind: .project, title: title, count: projectToolCount, state: .ok,
                    detail: "Файловые и git-инструменты · \(path)\(mode)"))
            case .notConfigured:
                result.append(ToolSourceSummary(
                    kind: .project, title: title, count: nil, state: .warning,
                    detail: "Каталог не выбран — инструменты не работают. Чип «Проект» → «Выбрать…» или Настройки → «Инструменты»."))
            case .broken(let path):
                result.append(ToolSourceSummary(
                    kind: .project, title: title, count: nil, state: .warning,
                    detail: "Папка не найдена: \(path)\(mode)"))
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

// MARK: - Чип состояния баз знаний (RAG)

/// Строка одной базы реестра в поповере чипа «База» (задача 34): состояние +
/// per-чат тумблер. Строятся чистыми билдерами ниже — покрыты тестами.
struct KnowledgeBaseChipRow: Identifiable, Equatable {
    let baseID: String
    let name: String
    /// База включена в ЭТОМ чате (per-чат мультивыбор).
    let enabledInChat: Bool
    let state: RagChipSummary.State
    let detail: String
    let health: ToolSourceSummary.Health

    var id: String { baseID }
}

/// Сводка состояния RAG для чипа «База» (задачи 28, 31, 34): агрегат по
/// включённым в чате базам реестра + строки для поповера с мультивыбором.
/// Отвечает на «почему агент не использует базу».
struct RagChipSummary: Equatable {
    enum State: Equatable {
        /// Индекс построен, эмбеддер доступен, теги совпадают.
        case ready(chunks: Int)
        /// Идёт индексация (fraction 0…1; nil — доля неизвестна).
        case indexing(fraction: Double?)
        /// Нет провайдера эмбеддингов — RAG невозможен.
        case noEmbedder
        /// Индекс пуст (vault: нужна индексация; проект/папка: построится сам).
        case empty
        /// Индекс построен другой моделью — нужна полная переиндексация (vault).
        case needsReindex
        /// Путь базы не существует: репозиторий не выбран / папка удалена.
        case pathMissing
    }

    /// Все строки реестра (и выключенные в чате — их можно включить из поповера).
    let rows: [KnowledgeBaseChipRow]
    let title: String
    let detail: String
    let health: ToolSourceSummary.Health
    /// Хоть одна включённая база индексируется (спиннер на чипе).
    let isIndexing: Bool

    /// nil — тумблер «По базе» выключен, чипа нет. Агрегат: заголовок по
    /// включённым базам, светофор — худший из включённых.
    static func make(ragEnabled: Bool, rows: [KnowledgeBaseChipRow]) -> RagChipSummary? {
        guard ragEnabled else { return nil }
        let enabled = rows.filter(\.enabledInChat)

        guard !enabled.isEmpty else {
            return RagChipSummary(
                rows: rows,
                title: "База: не выбрана",
                detail: "Ни одна база знаний не включена в этом чате — отметьте нужные.",
                health: .warning,
                isIndexing: false)
        }

        let title: String
        if enabled.count == 1, let only = enabled.first {
            if case .ready(let chunks) = only.state {
                title = "База: \(only.name) · \(chunks)"
            } else {
                title = "База: \(only.name)"
            }
        } else {
            title = "База: \(enabled[0].name) +\(enabled.count - 1)"
        }

        // Худшее состояние диктует светофор: warning > unknown > ok.
        let health: ToolSourceSummary.Health
        if enabled.contains(where: { $0.health == .warning }) {
            health = .warning
        } else if enabled.contains(where: { $0.health == .unknown }) {
            health = .unknown
        } else {
            health = .ok
        }

        let detail = enabled.count == 1
            ? enabled[0].detail
            : enabled.map { "\($0.name): \($0.detail)" }.joined(separator: "\n")

        return RagChipSummary(
            rows: rows,
            title: title,
            detail: detail,
            health: health,
            isIndexing: enabled.contains { row in
                if case .indexing = row.state { return true }
                return false
            })
    }

    // MARK: - Строки баз (чистые билдеры)

    static let noEmbedderDetail = "Нет модели эмбеддингов — установите nomic-embed-text во вкладке «Локальные модели» или добавьте ключ OpenAI/Gemini."

    /// Vault-приоритет: индексация → нет эмбеддера → смена модели → пусто → готов.
    static func vaultRow(base: KnowledgeBase,
                         enabledInChat: Bool,
                         embedderAvailable: Bool,
                         chunkCount: Int,
                         indexTag: String?,
                         currentTag: String?,
                         needsFullReindex: Bool,
                         isIndexing: Bool,
                         progressFraction: Double?) -> KnowledgeBaseChipRow {
        if isIndexing {
            return KnowledgeBaseChipRow(baseID: base.id, name: base.name,
                                        enabledInChat: enabledInChat,
                                        state: .indexing(fraction: progressFraction),
                                        detail: "Идёт индексация vault…",
                                        health: .unknown)
        }
        guard embedderAvailable else {
            return KnowledgeBaseChipRow(baseID: base.id, name: base.name,
                                        enabledInChat: enabledInChat,
                                        state: .noEmbedder, detail: noEmbedderDetail,
                                        health: .warning)
        }
        let tagMismatch = indexTag != nil && currentTag != nil && indexTag != currentTag
        if needsFullReindex || tagMismatch {
            return KnowledgeBaseChipRow(
                baseID: base.id, name: base.name, enabledInChat: enabledInChat,
                state: .needsReindex,
                detail: "Модель эмбеддинга изменилась — векторы несовместимы, нужна полная переиндексация.",
                health: .warning)
        }
        guard chunkCount > 0 else {
            return KnowledgeBaseChipRow(
                baseID: base.id, name: base.name, enabledInChat: enabledInChat,
                state: .empty,
                detail: "Индекс пуст — проиндексируйте vault, чтобы отвечать по заметкам.",
                health: .warning)
        }
        return KnowledgeBaseChipRow(
            baseID: base.id, name: base.name, enabledInChat: enabledInChat,
            state: .ready(chunks: chunkCount),
            detail: "Поиск по vault готов · чанков: \(chunkCount)",
            health: .ok)
    }

    /// Проект: нет репо → нет эмбеддера → пусто (построится сам) → готов.
    static func projectRow(base: KnowledgeBase,
                           enabledInChat: Bool,
                           projectRepo: ProjectRepoState,
                           embedderAvailable: Bool,
                           docsChunks: Int?) -> KnowledgeBaseChipRow {
        guard case .ready = projectRepo else {
            return KnowledgeBaseChipRow(
                baseID: base.id, name: base.name, enabledInChat: enabledInChat,
                state: .pathMissing,
                detail: "Репозиторий проекта не выбран — Настройки → «Инструменты».",
                health: .warning)
        }
        guard embedderAvailable else {
            return KnowledgeBaseChipRow(baseID: base.id, name: base.name,
                                        enabledInChat: enabledInChat,
                                        state: .noEmbedder, detail: noEmbedderDetail,
                                        health: .warning)
        }
        guard let docsChunks, docsChunks > 0 else {
            // Индекс доков строится лениво при первом вопросе — не ошибка.
            return KnowledgeBaseChipRow(
                baseID: base.id, name: base.name, enabledInChat: enabledInChat,
                state: .empty,
                detail: "Индекс документации построится при первом вопросе (README + docs репозитория).",
                health: .unknown)
        }
        return KnowledgeBaseChipRow(
            baseID: base.id, name: base.name, enabledInChat: enabledInChat,
            state: .ready(chunks: docsChunks),
            detail: "Поиск по документации репозитория готов · чанков: \(docsChunks)",
            health: .ok)
    }

    /// Папка: путь пропал → нет эмбеддера → пусто (построится сам) → готов.
    static func folderRow(base: KnowledgeBase,
                          enabledInChat: Bool,
                          folderExists: Bool,
                          embedderAvailable: Bool,
                          chunks: Int?) -> KnowledgeBaseChipRow {
        guard folderExists else {
            return KnowledgeBaseChipRow(
                baseID: base.id, name: base.name, enabledInChat: enabledInChat,
                state: .pathMissing,
                detail: "Папка не найдена: \(base.path)",
                health: .warning)
        }
        guard embedderAvailable else {
            return KnowledgeBaseChipRow(baseID: base.id, name: base.name,
                                        enabledInChat: enabledInChat,
                                        state: .noEmbedder, detail: noEmbedderDetail,
                                        health: .warning)
        }
        guard let chunks, chunks > 0 else {
            return KnowledgeBaseChipRow(
                baseID: base.id, name: base.name, enabledInChat: enabledInChat,
                state: .empty,
                detail: "Индекс папки построится при первом вопросе (.md-файлы, рекурсивно).",
                health: .unknown)
        }
        return KnowledgeBaseChipRow(
            baseID: base.id, name: base.name, enabledInChat: enabledInChat,
            state: .ready(chunks: chunks),
            detail: "Поиск по папке готов · чанков: \(chunks)",
            health: .ok)
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
