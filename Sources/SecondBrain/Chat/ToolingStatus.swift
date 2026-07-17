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
