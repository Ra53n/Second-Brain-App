// MCPManager.swift — агрегатор MCP-серверов (порт из MA): владеет
// соединениями, собирает инструменты, маршрутизирует вызовы по qualifiedName
// (`<slug>__<tool>`). Actor (Sendable): исполнитель-замыкание безопасно
// уходит в tool-use цикл.
//
// Перезапуск: авто-рестарта нет — упавший сервер срывает pending-вызовы
// понятной ошибкой, следующий ensureConnected пересоздаёт соединение.
// Таймауты: handshake 90 с (npx качает пакет при первом старте), вызов 120 с.

import Foundation

actor MCPManager {
    private var connections: [UUID: MCPConnection] = [:]
    private var specsByServer: [UUID: [ToolSpec]] = [:]
    private var routeByQualified: [String: (serverID: UUID, tool: String)] = [:]
    private var lastStatus: [UUID: MCPServerStatus] = [:]
    private var connecting: Set<UUID> = []

    /// Подключает (идемпотентно) все переданные включённые серверы.
    func ensureConnected(_ servers: [MCPServer]) async {
        for server in servers where server.enabled {
            _ = await connect(server)
        }
    }

    @discardableResult
    private func connect(_ server: MCPServer) async -> MCPServerStatus {
        // Уже подключён с инструментами — ничего не делаем.
        if let connection = connections[server.id],
           await connection.isRunning,
           let specs = specsByServer[server.id] {
            return statusFor(server, specs: specs, error: nil)
        }
        // Параллельный повторный вход (реентранси actor) — не плодим процессы.
        if connecting.contains(server.id) {
            return lastStatus[server.id]
                ?? MCPServerStatus(serverID: server.id, connected: false,
                                   toolCount: 0, toolNames: [], error: nil)
        }
        connecting.insert(server.id)
        defer { connecting.remove(server.id) }

        if let old = connections[server.id] { await old.shutdown() }
        let connection = MCPConnection(server: server)
        connections[server.id] = connection
        do {
            let tools = try await withTimeout(90) { try await connection.handshakeAndListTools() }
            let specs = tools.map { tool in
                ToolSpec(serverID: server.id,
                         serverName: server.name,
                         name: tool.name,
                         qualifiedName: Self.qualify(server: server, tool: tool.name),
                         description: tool.description,
                         schema: tool.inputSchema)
            }
            specsByServer[server.id] = specs
            for spec in specs { routeByQualified[spec.qualifiedName] = (server.id, spec.name) }
            return statusFor(server, specs: specs, error: nil)
        } catch {
            let diagnostics = await connection.diagnostics
            await connection.shutdown()
            connections[server.id] = nil
            specsByServer[server.id] = nil
            let base = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let message = diagnostics.isEmpty ? base : base + " · " + String(diagnostics.suffix(300))
            let status = MCPServerStatus(serverID: server.id, connected: false,
                                         toolCount: 0, toolNames: [], error: message)
            lastStatus[server.id] = status
            return status
        }
    }

    private func statusFor(_ server: MCPServer, specs: [ToolSpec], error: String?) -> MCPServerStatus {
        let status = MCPServerStatus(serverID: server.id,
                                     connected: error == nil,
                                     toolCount: specs.count,
                                     toolNames: specs.map(\.name),
                                     error: error)
        lastStatus[server.id] = status
        return status
    }

    /// Имя функции для LLM: `<slug>__<tool>`, только [A-Za-z0-9_-], ≤64 симв.
    static func qualify(server: MCPServer, tool: String) -> String {
        let raw = "\(server.slug)__\(tool)"
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(String(mapped).prefix(64))
    }

    func availableTools(serverIDs: Set<UUID>) -> [ToolSpec] {
        serverIDs.sorted { $0.uuidString < $1.uuidString }
            .flatMap { specsByServer[$0] ?? [] }
    }

    /// Выполнить инструмент. Никогда не бросает — ошибки возвращаются текстом
    /// с префиксом ERROR, чтобы модель в цикле могла среагировать.
    func call(qualifiedName: String, argumentsJSON: String) async -> String {
        guard let route = routeByQualified[qualifiedName],
              let connection = connections[route.serverID] else {
            return "ERROR: \(MCPError.unknownTool(qualifiedName).errorDescription ?? qualifiedName)"
        }
        let arguments = JSONValue.parse(argumentsJSON) ?? .object([:])
        do {
            return try await withTimeout(120) {
                try await connection.callTool(route.tool, arguments: arguments)
            }
        } catch {
            return "ERROR: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    func testConnection(_ server: MCPServer) async -> MCPServerStatus {
        await connect(server)
    }

    func status(for id: UUID) -> MCPServerStatus? { lastStatus[id] }

    func disconnect(_ id: UUID) async {
        if let connection = connections[id] { await connection.shutdown() }
        connections[id] = nil
        specsByServer[id] = nil
        routeByQualified = routeByQualified.filter { $0.value.serverID != id }
        lastStatus[id] = nil
    }

    func disconnectAll() async {
        for (_, connection) in connections { await connection.shutdown() }
        connections.removeAll()
        specsByServer.removeAll()
        routeByQualified.removeAll()
    }
}
