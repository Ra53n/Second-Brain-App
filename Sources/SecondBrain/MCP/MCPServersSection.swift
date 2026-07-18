// MCPServersSection.swift — UI управления MCP-серверами (задача 15):
// список со статусами, добавление/редактирование (command/args/env,
// keychain:-синтаксис для секретов), импорт конфига Claude Desktop, тест
// подключения. Живёт в «Настройках» рядом с локальными моделями.

import SwiftUI

/// Владелец списка серверов и менеджера соединений.
@MainActor
final class MCPServersViewModel: ObservableObject {
    @Published private(set) var servers: [MCPServer]
    @Published private(set) var statuses: [UUID: MCPServerStatus] = [:]
    @Published var editingServer: MCPServer?
    @Published var showsImport = false
    @Published private(set) var testingID: UUID?

    let manager = MCPManager()
    private let fileURL: URL

    init(fileURL: URL = MCPServerStore.defaultFileURL) {
        self.fileURL = fileURL
        self.servers = MCPServerStore.load(from: fileURL)
    }

    func upsert(_ server: MCPServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        MCPServerStore.save(servers, to: fileURL)
        // Конфиг изменился — старое соединение недействительно.
        Task { await manager.disconnect(server.id) }
    }

    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        statuses[id] = nil
        MCPServerStore.save(servers, to: fileURL)
        Task { await manager.disconnect(id) }
    }

    func importClaudeConfig(_ text: String) -> Int {
        let imported = MCPServer.parseClaudeConfig(text)
        for server in imported { upsert(server) }
        return imported.count
    }

    func test(_ server: MCPServer) {
        guard testingID == nil else { return }
        testingID = server.id
        Task { [weak self] in
            let status = await self?.manager.testConnection(server)
            if let status { self?.statuses[server.id] = status }
            self?.testingID = nil
        }
    }

    /// Инструменты включённых серверов чата (для tool-use цикла).
    func tools(for serverIDs: Set<UUID>) async -> [ToolDefinition] {
        let selected = servers.filter { serverIDs.contains($0.id) && $0.enabled }
        guard !selected.isEmpty else { return [] }
        await manager.ensureConnected(selected)
        for server in selected {
            if let status = await manager.status(for: server.id) {
                statuses[server.id] = status
            }
        }
        return await manager.availableTools(serverIDs: Set(selected.map(\.id)))
            .map(ToolDefinition.init)
    }
}

struct MCPServersSection: View {
    @ObservedObject var viewModel: MCPServersViewModel
    /// Путь репозитория проекта (задача 21) — предзаполнение шаблона git.
    var projectRepoPath: String = ""

    var body: some View {
        Section("MCP-серверы (инструменты для чата)") {
            if viewModel.servers.isEmpty {
                Text("Серверов нет. Добавьте вручную, импортируйте конфиг Claude Desktop или начните с шаблона Atlassian (Jira/Confluence).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.servers) { server in
                serverRow(server)
            }
            HStack {
                Button("Новый") {
                    viewModel.editingServer = MCPServer()
                }
                .help("Добавить MCP-сервер вручную (команда, аргументы, окружение)")
                Button("Atlassian (шаблон)") {
                    viewModel.editingServer = MCPServer.atlassianTemplate()
                }
                .help("Заготовка Jira/Confluence через официальный mcp-remote (OAuth в браузере)")
                Button("Git (шаблон)") {
                    viewModel.editingServer = MCPServer.gitTemplate(
                        repositoryPath: projectRepoPath)
                }
                .help("Заготовка mcp-server-git (uvx) — внешняя альтернатива встроенным git-инструментам")
                Button("Импорт из Claude…") {
                    viewModel.showsImport = true
                }
                .help("Вставить блок mcpServers из конфига Claude Desktop")
            }
            Text("Секреты в env: значение «keychain:имя» подставляется из Keychain при запуске (токен не лежит в конфиге). Рекомендуемые модели для инструментов: GPT-4o+, qwen3+ (локально).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $viewModel.editingServer) { server in
            MCPServerEditorView(server: server) { viewModel.upsert($0) }
        }
        .sheet(isPresented: $viewModel.showsImport) {
            MCPImportView { viewModel.importClaudeConfig($0) }
        }
    }

    @ViewBuilder
    private func serverRow(_ server: MCPServer) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(server))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name.isEmpty ? "(без имени)" : server.name)
                Text(statusLine(server))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if viewModel.testingID == server.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Тест") { viewModel.test(server) }
                    .controlSize(.small)
                    .help("Проверить запуск сервера и получить список инструментов")
            }
            Button {
                viewModel.editingServer = server
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Редактировать сервер")
            Button(role: .destructive) {
                viewModel.remove(server.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Удалить сервер")
        }
    }

    private func statusColor(_ server: MCPServer) -> Color {
        guard server.enabled else { return .secondary.opacity(0.3) }
        guard let status = viewModel.statuses[server.id] else { return .secondary.opacity(0.5) }
        return status.connected ? .green : .orange
    }

    private func statusLine(_ server: MCPServer) -> String {
        guard server.enabled else { return "выключен" }
        guard let status = viewModel.statuses[server.id] else {
            return "\(server.command) \(server.args.joined(separator: " "))"
        }
        if let error = status.error { return error }
        return "инструментов: \(status.toolCount)"
    }
}

/// Редактор сервера: command/args/env/extraPATH.
struct MCPServerEditorView: View {
    @State var server: MCPServer
    let onSave: (MCPServer) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var argsText = ""
    @State private var envText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MCP-сервер").font(.headline)
            TextField("Имя (префикс инструментов)", text: $server.name)
            TextField("Команда (например npx)", text: $server.command)
            Toggle("Включён", isOn: $server.enabled)
            Text("Аргументы — по одному на строку:")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $argsText)
                .font(.callout.monospaced())
                .frame(minHeight: 60, maxHeight: 110)
            Text("Переменные окружения — KEY=VALUE (секрет: KEY=keychain:имя-в-keychain):")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $envText)
                .font(.callout.monospaced())
                .frame(minHeight: 40, maxHeight: 90)
            TextField("Доп. PATH (опционально)", text: $server.extraPATH)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    server.args = argsText.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    server.env = Self.parseEnv(envText)
                    onSave(server)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 480)
        .onAppear {
            argsText = server.args.joined(separator: "\n")
            envText = server.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        }
    }

    static func parseEnv(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = String(parts[1])
        }
        return env
    }
}

/// Импорт JSON-блока mcpServers из Claude Desktop.
struct MCPImportView: View {
    let onImport: (String) -> Int
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var importedCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Импорт конфига Claude Desktop").font(.headline)
            Text("Вставьте JSON вида {\"mcpServers\": {\"имя\": {\"command\": …}}}")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(minHeight: 160)
            if let importedCount {
                Text(importedCount > 0 ? "Импортировано серверов: \(importedCount)"
                                       : "Ничего не распознано — проверьте формат.")
                    .font(.caption)
                    .foregroundStyle(importedCount > 0 ? .green : .orange)
            }
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                Button("Импортировать") { importedCount = onImport(text) }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 480)
    }
}
