// MCPServer.swift — конфиг MCP-сервера, окружение подпроцесса, персистентность.
//
// Конфиг в стиле Claude Desktop (command/args/env) — пользователю знаком,
// поддержан импорт JSON-блока `mcpServers`. Хранение: mcp-servers.json в
// Application Support (вне репозитория).
//
// Секреты: значение env вида `keychain:<имя>` резолвится при запуске через
// KeyStore (Keychain + env-fallback) — токены Jira/Confluence НЕ лежат в
// plaintext-конфиге. Обычные значения передаются как есть (совместимость с
// импортом из Claude Desktop).

import Foundation

/// MCP-сервер: команда запуска + аргументы + env.
struct MCPServer: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var command: String = "npx"
    var args: [String] = []
    var env: [String: String] = [:]
    var enabled: Bool = true
    /// Доп. каталоги PATH (нестандартная установка node и т.п.).
    var extraPATH: String = ""

    /// Безопасный слаг имени для префикса инструментов (a–z0–9_).
    var slug: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let mapped = name.lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "_"
        }
        let s = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? "mcp" : String(s.prefix(24))
    }

    enum CodingKeys: String, CodingKey { case id, name, command, args, env, enabled, extraPATH }

    init() {}

    /// Снисходительное декодирование: новые поля не ломают старый конфиг.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MCPServer()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? d.command
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? d.args
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? d.env
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        extraPATH = try c.decodeIfPresent(String.self, forKey: .extraPATH) ?? d.extraPATH
    }

    /// Шаблон Atlassian (Jira/Confluence) через официальный mcp-remote — без
    /// секретов, авторизация OAuth в браузере при первом подключении.
    static func atlassianTemplate() -> MCPServer {
        var s = MCPServer()
        s.name = "atlassian"
        s.command = "npx"
        s.args = ["-y", "mcp-remote", "https://mcp.atlassian.com/v1/sse"]
        s.enabled = false
        return s
    }

    /// Шаблон официального git MCP-сервера (mcp-server-git, Python) через uvx —
    /// внешняя альтернатива встроенным инструментам задачи 21: полный набор
    /// git-операций, ВКЛЮЧАЯ изменяющие (add/commit и т.п.) — включать осознанно.
    static func gitTemplate(repositoryPath: String = "") -> MCPServer {
        var s = MCPServer()
        s.name = "git"
        s.command = "uvx"
        s.args = ["mcp-server-git"]
            + (repositoryPath.isEmpty ? [] : ["--repository", repositoryPath])
        s.enabled = false
        return s
    }

    /// Разбор JSON-блока в стиле Claude Desktop:
    /// `{ "mcpServers": { "<имя>": { command, args, env } } }` (или сразу карта).
    static func parseClaudeConfig(_ text: String) -> [MCPServer] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        let map = root["mcpServers"]?.objectValue ?? root.objectValue ?? [:]
        var out: [MCPServer] = []
        for (name, value) in map {
            guard let object = value.objectValue else { continue }
            var server = MCPServer()
            server.name = name
            server.command = object["command"]?.stringValue ?? "npx"
            server.args = object["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if let envObject = object["env"]?.objectValue {
                var env: [String: String] = [:]
                for (key, envValue) in envObject {
                    if let string = envValue.stringValue { env[key] = string }
                }
                server.env = env
            }
            server.enabled = true
            out.append(server)
        }
        return out.sorted { $0.name < $1.name }
    }
}

// MARK: - Окружение подпроцесса

/// Сборка окружения MCP-сервера. GUI-.app из Finder получает минимальный PATH
/// без nvm/homebrew — npx/node не находятся; дополняем типовыми каталогами.
enum MCPEnv {
    /// Префикс env-значения, резолвящегося из Keychain через KeyStore.
    static let keychainPrefix = "keychain:"

    static func augmentedPATH(extra: String) -> String {
        var dirs: [String] = []
        if !extra.isEmpty { dirs += extra.split(separator: ":").map(String.init) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for version in versions.sorted(by: >) { dirs.append("\(nvm)/\(version)/bin") }
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
        if let current = ProcessInfo.processInfo.environment["PATH"] {
            dirs += current.split(separator: ":").map(String.init)
        }
        dirs += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        var seen = Set<String>()
        var out: [String] = []
        for dir in dirs where !dir.isEmpty && !seen.contains(dir) {
            seen.insert(dir)
            out.append(dir)
        }
        return out.joined(separator: ":")
    }

    /// env для ребёнка: значения `keychain:<имя>` резолвятся через KeyStore
    /// (нет ключа → пустая строка и понятная диагностика на сервере).
    static func childEnvironment(_ server: MCPServer,
                                 keyLookup: (String) -> String? = { KeyStore.key(for: ProviderID(rawValue: $0)) }) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in server.env {
            env[key] = resolveSecret(value, keyLookup: keyLookup)
        }
        env["PATH"] = augmentedPATH(extra: server.extraPATH)
        return env
    }

    /// `keychain:jira-token` → значение из Keychain; иначе значение как есть.
    static func resolveSecret(_ value: String, keyLookup: (String) -> String?) -> String {
        guard value.hasPrefix(keychainPrefix) else { return value }
        let account = String(value.dropFirst(keychainPrefix.count))
        return keyLookup(account) ?? ""
    }
}

// MARK: - Персистентность

/// mcp-servers.json в Application Support (может содержать секреты в args —
/// вне репозитория; для секретов в env рекомендован keychain:-синтаксис).
enum MCPServerStore {
    static var defaultFileURL: URL {
        Config.appSupportDirectory.appendingPathComponent("mcp-servers.json")
    }

    static func load(from url: URL = defaultFileURL) -> [MCPServer] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([MCPServer].self, from: data)
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    static func save(_ servers: [MCPServer], to url: URL = defaultFileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
