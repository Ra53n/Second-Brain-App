// ToolPermissions.swift — слой разрешений инструментов (задача 39).
//
// Аналог permission modes Claude Code: каждый вызов инструмента (встроенного
// или MCP) классифицируется по риску, режим чата решает — выполнять сразу
// или спрашивать пользователя. Классификатор — чистая функция без I/O,
// исчерпывающе покрыт тестами (ToolPermissionsTests).
//
// Уровни риска:
//  - safe      — чтение и анализ (файлы, git-обзор, поиск, rag_search) и
//                команды из безопасного списка (сборка, тесты);
//  - write     — создание/изменение файлов и MCP-вызовы (побочный эффект
//                неизвестен приложению — закрывает BACKLOG п. 10);
//  - dangerous — удаление, произвольные команды (push, скрипты, сеть) и
//                правки скрытых файлов/конфигов.

import Foundation

/// Уровень риска конкретного вызова (имя инструмента + аргументы).
enum ToolRiskLevel: Int, Codable, Comparable {
    case safe = 0, write = 1, dangerous = 2

    static func < (lhs: ToolRiskLevel, rhs: ToolRiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Подпись уровня в карточке подтверждения.
    var label: String {
        switch self {
        case .safe: return "безопасная"
        case .write: return "правка"
        case .dangerous: return "опасная"
        }
    }
}

/// Режим работы агента per-чат (persisted в ChatConfiguration).
enum AgentPermissionMode: String, Codable, CaseIterable {
    /// Спрашивать: подтверждение на правки и опасные операции.
    case ask
    /// Авто: правки без вопросов, опасные — подтверждение.
    case auto
    /// Авто-опасный: всё выполняется без подтверждений.
    case autoDanger

    /// Незнакомое значение «из будущего» → самый строгий режим.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentPermissionMode(rawValue: raw) ?? .ask
    }

    var label: String {
        switch self {
        case .ask: return "Спрашивать"
        case .auto: return "Авто"
        case .autoDanger: return "Авто-опасный"
        }
    }

    var help: String {
        switch self {
        case .ask:
            return "Подтверждение на каждую правку файлов и опасную операцию."
        case .auto:
            return "Правки файлов и MCP-вызовы — без вопросов; опасные операции (удаление, произвольные команды) — с подтверждением."
        case .autoDanger:
            return "ВСЕ операции выполняются без подтверждений — ответственность на вас."
        }
    }
}

/// Решение слоя разрешений: выполнять / спросить пользователя.
enum ToolPermissionPolicy {
    static func requiresApproval(mode: AgentPermissionMode, risk: ToolRiskLevel) -> Bool {
        switch mode {
        case .ask: return risk >= .write
        case .auto: return risk >= .dangerous
        case .autoDanger: return false
        }
    }
}

/// Классификатор риска вызова. Чистые функции — без обращения к диску.
enum ToolRiskClassifier {
    /// Встроенные инструменты только-чтения/анализа.
    private static let safeBuiltins: Set<String> = [
        "read_file", "list_files", "search_files",
        "git_branches", "git_status", "git_log", "git_diff",
        RagSearchTool.toolName
    ]

    /// Безопасные префиксы команд run_command: сборка, тесты, обзор.
    /// Каждый элемент — токены начала команды; сравнение по префиксу.
    static let safeCommandPrefixes: [[String]] = [
        ["swift", "build"], ["swift", "test"],
        ["git", "status"], ["git", "log"], ["git", "diff"], ["git", "show"],
        ["ls"], ["pwd"], ["cat"], ["head"], ["tail"], ["wc"],
        ["grep"], ["rg"], ["file"], ["du"],
        ["xcodebuild", "-list"]
    ]

    /// Риск вызова по имени и аргументам (JSON-строка от модели).
    static func classify(name: String, argumentsJSON: String) -> ToolRiskLevel {
        classify(name: name, arguments: JSONValue.parse(argumentsJSON) ?? .object([:]))
    }

    static func classify(name: String, arguments: JSONValue) -> ToolRiskLevel {
        // MCP-инструменты всегда «slug__tool»: побочный эффект неизвестен —
        // уровень write (в режиме ask спросим; прежнее поведение = auto).
        if name.contains("__") { return .write }
        if safeBuiltins.contains(name) { return .safe }
        switch name {
        case "write_file", "edit_file":
            let path = arguments["path"]?.stringValue ?? ""
            return isConfigPath(path) ? .dangerous : .write
        case "delete_file":
            return .dangerous
        case "fetch_url":
            // Сетевой egress — побочный эффект неизвестен приложению, как MCP.
            return .write
        case "run_command":
            return classifyCommand(arguments["command"]?.stringValue ?? "")
        default:
            // Незнакомый инструмент — считаем опасным (защитный дефолт).
            return .dangerous
        }
    }

    /// «Конфиг-пути»: скрытые файлы и папки (.git/, .env, .github/…) —
    /// правка через write/edit считается опасной, а не обычной.
    static func isConfigPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Риск команды shell: safe — ВСЕ сегменты (разбивка по && ; | ||)
    /// начинаются с безопасного префикса и нет редиректов/подстановок;
    /// иначе dangerous (push, rm, curl, скрипты, сеть — всё сюда).
    static func classifyCommand(_ command: String) -> ToolRiskLevel {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .dangerous }
        // Редирект пишет файлы, подстановки выполняют произвольный код.
        for marker in [">", "<", "`", "$(", "--output"] where trimmed.contains(marker) {
            return .dangerous
        }
        for segment in splitSegments(trimmed) {
            let tokens = segment.split(separator: " ").map(String.init)
            guard !tokens.isEmpty else { return .dangerous }
            let isSafe = safeCommandPrefixes.contains { prefix in
                tokens.count >= prefix.count
                    && Array(tokens.prefix(prefix.count)) == prefix
            }
            guard isSafe else { return .dangerous }
        }
        return .safe
    }

    /// Ключ операции для сессионного allowlist («Разрешить на сессию»):
    /// run_command — нормализованная команда целиком, остальные — имя.
    static func operationKey(name: String, argumentsJSON: String) -> String {
        guard name == "run_command",
              let command = JSONValue.parse(argumentsJSON)?["command"]?.stringValue
        else { return name }
        let normalized = command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "run_command:\(normalized)"
    }

    /// Разбивка команды на сегменты по && ; | || (порядок важен: сначала
    /// двухсимвольные операторы, чтобы «||» не распался на два «|»).
    private static func splitSegments(_ command: String) -> [String] {
        var segments = [command]
        for separator in ["&&", "||", ";", "|"] {
            segments = segments.flatMap { $0.components(separatedBy: separator) }
        }
        return segments
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
