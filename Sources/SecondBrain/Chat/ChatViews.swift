// ChatViews.swift — UI раздела «Чат» (задача 12): список чатов в средней
// колонке, диалог в detail (лента с markdown-рендером, стриминг, поле ввода,
// пикер модели в тулбаре, отмена генерации, баннер ошибки).

import MarkdownUI
import SwiftUI

// MARK: - Список чатов (средняя колонка)

struct ChatListPane: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedChatID) {
                if viewModel.chats.isEmpty {
                    Text("Чатов пока нет. Нажмите «+».")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.chats) { chat in
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left")
                            .foregroundStyle(.secondary)
                        Text(chat.title)
                            .lineLimit(1)
                        Spacer()
                        if chat.isLoading {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .tag(chat.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.deleteChat(chat.id)
                        } label: {
                            Label("Удалить чат", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.newChat()
                } label: {
                    Label("Новый чат", systemImage: "square.and.pencil")
                }
            }
        }
    }
}

// MARK: - Диалог (detail)

struct ChatDetailView: View {
    @ObservedObject var viewModel: ChatViewModel
    /// Резолвер [[wikilink]] → URL заметки (LinkIndex задачи 04); nil — vault закрыт.
    var resolveWikilink: (String) -> URL? = { _ in nil }
    /// Список MCP-серверов для меню инструментов (задача 15).
    var mcpServers: [MCPServer] = []

    private var chat: Chat? { viewModel.selectedChat }

    var body: some View {
        VStack(spacing: 0) {
            messagesList
            Divider()
            errorBar
            inputBar
        }
        .navigationTitle(chat?.title ?? "Чат")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { mcpMenu }
            ToolbarItem(placement: .primaryAction) { ragToggle }
            ToolbarItem(placement: .primaryAction) { modelPicker }
        }
        // Клик по wikilink в ответе → открыть заметку в разделе «Заметки».
        .environment(\.openURL, OpenURLAction { url in
            guard let target = ChatWikilinkRenderer.target(from: url) else {
                return .systemAction
            }
            openNote(target: target)
            return .handled
        })
    }

    /// Меню инструментов: встроенные инструменты проекта (задача 21) и
    /// чекбоксы MCP-серверов per-чат (задача 15).
    @ViewBuilder
    private var mcpMenu: some View {
        if !mcpServers.isEmpty || viewModel.projectToolsAvailable {
            Menu {
                if viewModel.projectToolsAvailable {
                    Button {
                        viewModel.toggleProjectTools()
                    } label: {
                        let enabled = chat?.configuration.projectToolsEnabled ?? false
                        if enabled {
                            Label("Инструменты проекта (git)", systemImage: "checkmark")
                        } else {
                            Text("Инструменты проекта (git)")
                        }
                    }
                    if !mcpServers.filter(\.enabled).isEmpty { Divider() }
                }
                ForEach(mcpServers.filter(\.enabled)) { server in
                    Button {
                        viewModel.toggleMCPServer(server.id)
                    } label: {
                        let enabled = chat?.configuration.enabledMCPServerIDs
                            .contains(server.id) ?? false
                        if enabled {
                            Label(server.name, systemImage: "checkmark")
                        } else {
                            Text(server.name)
                        }
                    }
                }
                Divider()
                Text("Инструменты требуют модель с function calling: GPT-4o+, qwen3+.")
            } label: {
                Label(enabledToolSourcesCount > 0
                      ? "Инструменты (\(enabledToolSourcesCount))" : "Инструменты",
                      systemImage: enabledToolSourcesCount > 0 ? "wrench.and.screwdriver.fill"
                                                               : "wrench.and.screwdriver")
            }
            .help("Инструменты, доступные модели в этом чате: git-обзор проекта и MCP-серверы")
        }
    }

    /// Счётчик включённых источников инструментов (MCP-серверы + проект).
    private var enabledToolSourcesCount: Int {
        let mcp = chat?.configuration.enabledMCPServerIDs.count ?? 0
        let project = (chat?.configuration.projectToolsEnabled ?? false) ? 1 : 0
        return mcp + project
    }

    /// Тумблер «Отвечать по базе» (persisted per-чат).
    private var ragToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.ragEnabledBinding },
            set: { viewModel.ragEnabledBinding = $0 }
        )) {
            Label("По базе", systemImage: "books.vertical")
        }
        .toggleStyle(.button)
        .help("Отвечать по содержимому vault (RAG)")
    }

    private func openNote(target: String) {
        guard let url = resolveWikilink(target) else { return }
        NotificationCenter.default.post(name: .openNoteInEditor, object: url)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let chat, chat.messages.isEmpty {
                        Text("Напишите сообщение, чтобы начать диалог.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(chat?.messages ?? []) { message in
                        MessageBubble(message: message,
                                      resolveWikilink: resolveWikilink,
                                      openNote: openNote)
                            .id(message.id)
                    }
                }
                .padding()
            }
            // Автопрокрутка к последнему сообщению (стриминг дописывает вниз).
            .onChange(of: chat?.messages.last?.content) {
                if let lastID = chat?.messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var errorBar: some View {
        if let error = chat?.errorText {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Сообщение… (⌘⏎ — отправить)",
                      text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...8)
                .onSubmit { if viewModel.canSend { viewModel.send() } }

            if chat?.isLoading == true {
                Button {
                    if let id = chat?.id { viewModel.cancelGeneration(chatID: id) }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("Остановить генерацию")
            } else {
                Button {
                    viewModel.send()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10)
    }

    /// Пикер модели: провайдеры с capability .chat (локальные помечены);
    /// «Авто» — вернуться к выбору роутера.
    private var modelPicker: some View {
        Menu {
            Button {
                viewModel.setModel(providerID: nil, model: nil)
            } label: {
                if chat?.configuration.providerID == nil {
                    Label("Авто (роутер)", systemImage: "checkmark")
                } else {
                    Text("Авто (роутер)")
                }
            }
            Divider()
            ForEach(viewModel.chatProviderOptions) { descriptor in
                Button {
                    viewModel.setModel(providerID: descriptor.id, model: descriptor.defaultModel)
                } label: {
                    let name = descriptor.isLocal
                        ? "\(descriptor.displayName) — локально"
                        : descriptor.displayName
                    let title = descriptor.defaultModel.map { "\(name) · \($0)" } ?? name
                    if chat?.configuration.providerID == descriptor.id {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
                .disabled(!viewModel.registry.isAvailable(descriptor.id))
            }
        } label: {
            Label(currentModelTitle, systemImage: "cpu")
        }
        .help("Модель для этого чата")
    }

    private var currentModelTitle: String {
        guard let chat else { return "Модель" }
        if let providerID = chat.configuration.providerID {
            let name = viewModel.registry.descriptor(for: providerID)?.displayName
                ?? providerID.rawValue
            return chat.configuration.model.map { "\(name) · \($0)" } ?? name
        }
        return "Авто"
    }
}

/// Пузырь одного сообщения: markdown-рендер с кликабельными [[wikilinks]],
/// блок «Источники» и метрики под ответом.
struct MessageBubble: View {
    let message: ChatMessage
    var resolveWikilink: (String) -> URL? = { _ in nil }
    var openNote: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .user ? "Вы" : "Ассистент")
                .font(.caption2)
                .foregroundStyle(.secondary)
            toolCallsBlock
            Markdown(renderedContent)
                .markdownTheme(.docC)
                .textSelection(.enabled)
            sourcesBlock
            if let metrics = message.metrics {
                Text(metricsLine(metrics))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(message.role == .user
                      ? Color.accentColor.opacity(0.08)
                      : Color.secondary.opacity(0.06))
        )
    }

    /// [[wikilinks]] в ответах ассистента → ссылки/пометки галлюцинаций.
    private var renderedContent: String {
        guard !message.content.isEmpty else { return "…" }
        guard message.role == .assistant else { return message.content }
        return ChatWikilinkRenderer.render(message.content) { target in
            resolveWikilink(target) != nil
        }
    }

    /// Вызовы MCP-инструментов (задача 15): свёрнутый блок с именем,
    /// аргументами и результатом каждого вызова.
    @ViewBuilder
    private var toolCallsBlock: some View {
        if let calls = message.toolCalls, !calls.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(calls) { call in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(call.name,
                                  systemImage: call.ok ? "checkmark.circle" : "xmark.circle")
                                .font(.caption.bold())
                                .foregroundStyle(call.ok ? Color.primary : .orange)
                            if !call.argumentsJSON.isEmpty, call.argumentsJSON != "{}" {
                                Text(call.argumentsJSON)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                            Text(call.result)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                                .textSelection(.enabled)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.08)))
                    }
                }
            } label: {
                Label("Инструменты (\(calls.count))", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// «Источники»: чанки, ушедшие в [RAG_CONTEXT] (задача 14). Клик — заметка;
    /// нерезолвящийся источник (заметку удалили) помечен и не кликабелен.
    @ViewBuilder
    private var sourcesBlock: some View {
        if let sources = message.sources, !sources.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Источники")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(sources) { source in
                    let resolvable = resolveWikilink(source.noteName) != nil
                    Button {
                        openNote(source.noteName)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: resolvable ? "doc.text" : "exclamationmark.triangle")
                            Text(sourceLine(source))
                                .lineLimit(1)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(resolvable ? Color.accentColor : .orange)
                    .disabled(!resolvable)
                }
            }
            .padding(.top, 4)
        }
    }

    private func sourceLine(_ source: RagSource) -> String {
        var line = source.noteName
        if !source.headingPath.isEmpty { line += " · \(source.headingPath)" }
        line += String(format: " · %.0f %%", max(0, source.score) * 100)
        return line
    }

    private func metricsLine(_ metrics: MessageMetrics) -> String {
        var parts = [String(format: "%.1f c", metrics.duration)]
        if let total = metrics.totalTokens { parts.append("\(total) ток.") }
        return parts.joined(separator: " · ")
    }
}
