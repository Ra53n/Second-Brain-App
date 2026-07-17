// ChatViews.swift — UI раздела «Чат» (задача 12): список чатов в средней
// колонке, диалог в detail (лента с markdown-рендером, стриминг, поле ввода,
// пикер модели в тулбаре, отмена генерации, баннер ошибки).

import AppKit
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
                .help("Новый чат")
            }
        }
    }
}

// MARK: - Диалог (detail)

struct ChatDetailView: View {
    @ObservedObject var viewModel: ChatViewModel
    /// Наблюдаем настройки напрямую (задача 27): projectToolsAvailable читает
    /// их через замыкание и не публикует изменения — без этого мастер и чип
    /// «Проект» не обновлялись бы после выбора репозитория в настройках.
    @ObservedObject var settingsStore: SettingsStore
    /// MCP-вью-модель целиком (задача 27): servers для меню + statuses для
    /// чипов (зеленеют после «Тест» и первого tool-вызова).
    @ObservedObject var mcpViewModel: MCPServersViewModel
    /// Показ попапа настроек RAG (задача 23).
    @State private var showsRagTuning = false
    /// Открытие окна настроек из пикера модели (задача 24).
    @Environment(\.openSettings) private var openSettings
    /// Доступность провайдера (KeyStore/рантайм) не Combine-наблюдаема — тик
    /// по фокусу окна перечитывает её при возврате из настроек (задача 27;
    /// прецедент — keyChangeTick в ProvidersSettingsTab).
    @State private var availabilityTick = 0
    /// Резолвер [[wikilink]] → URL заметки (LinkIndex задачи 04); nil — vault закрыт.
    var resolveWikilink: (String) -> URL? = { _ in nil }

    private var chat: Chat? { viewModel.selectedChat }

    /// Сводки чипов текущего чата (чистый билдер — покрыт тестами).
    private var toolSourceSummaries: [ToolSourceSummary] {
        guard let chat else { return [] }
        return ToolSourceSummary.make(
            configuration: chat.configuration,
            projectRepo: ProjectRepoState.evaluate(path: settingsStore.settings.projectRepoPath),
            projectToolCount: ToolRegistry.projectToolCatalog().count,
            servers: mcpViewModel.servers,
            statuses: mcpViewModel.statuses)
    }

    /// Состояние мастера; читает availabilityTick, чтобы перечитываться
    /// после возврата из окна настроек.
    private var wizardState: ProjectWizardState {
        _ = availabilityTick
        return ProjectWizardState.make(
            repoConfigured: !settingsStore.settings.projectRepoPath
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            providerAvailable: viewModel.chatProviderAvailable,
            toolsEnabledInChat: chat?.configuration.projectToolsEnabled ?? false)
    }

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
            ToolbarItem(placement: .primaryAction) { ragTuningButton }
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
        // Перечитка доступности провайдера при возврате из окна настроек.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification)) { _ in
            availabilityTick &+= 1
        }
    }

    /// Меню инструментов: встроенные инструменты проекта (задача 21) и
    /// чекбоксы MCP-серверов per-чат (задача 15). Видно всегда (задача 27):
    /// пункт «Добавить инструменты…» — точка входа в настройку туллинга.
    private var mcpMenu: some View {
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
                if !mcpViewModel.servers.filter(\.enabled).isEmpty { Divider() }
            }
            ForEach(mcpViewModel.servers.filter(\.enabled)) { server in
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
            Button("Добавить инструменты…") {
                SettingsTabRouter.open(.tools, openSettings: { openSettings() })
            }
            Text("Инструменты требуют модель с function calling: GPT-4o+, qwen3+.")
        } label: {
            Label(enabledToolSourcesCount > 0
                  ? "Инструменты (\(enabledToolSourcesCount))" : "Инструменты",
                  systemImage: enabledToolSourcesCount > 0 ? "wrench.and.screwdriver.fill"
                                                           : "wrench.and.screwdriver")
        }
        .help("Инструменты, доступные модели в этом чате: git-обзор проекта и MCP-серверы")
    }

    /// Счётчик включённых источников инструментов — по тем же правилам, что
    /// чипы («осиротевшие» serverID удалённых серверов не считаются).
    private var enabledToolSourcesCount: Int {
        toolSourceSummaries.count
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

    /// Кнопка тонких настроек RAG (задача 23): topK/minScore/rerank/rewrite,
    /// которые с задачи 14 жили только в JSON-конфиге.
    private var ragTuningButton: some View {
        Button {
            showsRagTuning.toggle()
        } label: {
            Label("Параметры RAG", systemImage: "slider.horizontal.3")
        }
        .help("Параметры поиска по базе (topK, порог, переранжирование)")
        .popover(isPresented: $showsRagTuning) {
            RagTuningPopover(viewModel: viewModel)
        }
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
                        // Мастер настройки ассистента проекта (задача 27):
                        // живые ✓/○, исчезает с первым сообщением.
                        ProjectWizardCard(
                            state: wizardState,
                            onPickRepo: { ProjectRepoPicker.pick(into: settingsStore) },
                            onOpenSettings: { tab in
                                SettingsTabRouter.open(tab, openSettings: { openSettings() })
                            },
                            onEnableTools: {
                                if chat.configuration.projectToolsEnabled == false {
                                    viewModel.toggleProjectTools()
                                }
                            })
                            .padding(.horizontal)
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
        VStack(alignment: .leading, spacing: 4) {
            toolChipsRow
            slashCommandHint
            inputRow
        }
        .padding(10)
    }

    /// Чипы включённых источников инструментов (задача 27): видно без
    /// единого клика, поповер чипа — статус и быстрые действия.
    @ViewBuilder
    private var toolChipsRow: some View {
        if !toolSourceSummaries.isEmpty {
            ToolChipsRow(
                summaries: toolSourceSummaries,
                onDisable: { summary in
                    switch summary.kind {
                    case .project: viewModel.toggleProjectTools()
                    case .mcp(let serverID): viewModel.toggleMCPServer(serverID)
                    }
                },
                onConfigure: {
                    SettingsTabRouter.open(.tools, openSettings: { openSettings() })
                })
        }
    }

    /// Подсказка слэш-команд (задача 22): пока пользователь набирает «/имя»
    /// без пробела — список доступных команд. Полноценный autocomplete — бэклог.
    @ViewBuilder
    private var slashCommandHint: some View {
        let trimmed = viewModel.input.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/"), !trimmed.contains(where: \.isWhitespace) {
            Text(SlashCommand.catalog.map { "\($0.name) — \($0.summary)" }
                .joined(separator: "\n"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private var inputRow: some View {
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
                if viewModel.canRegenerate {
                    Button {
                        viewModel.regenerateLastAnswer()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("Перегенерировать последний ответ")
                }
                Button {
                    viewModel.send()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Отправить (⌘⏎)")
            }
        }
    }

    /// Пикер модели: провайдеры с capability .chat (локальные помечены);
    /// «Авто» — вернуться к выбору роутера. Недоступные провайдеры выбираемы
    /// (задача 24): причина видна в названии, путь решения — «Открыть
    /// настройки…»; серые некликабельные пункты только запутывали.
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
                    if chat?.configuration.providerID == descriptor.id {
                        Label(providerMenuTitle(descriptor), systemImage: "checkmark")
                    } else {
                        Text(providerMenuTitle(descriptor))
                    }
                }
            }
            Divider()
            Button("Открыть настройки…") { openSettings() }
            Text("Ключи облачных провайдеров — вкладка «Провайдеры», запуск Ollama/WhisperKit — «Локальные модели».")
        } label: {
            Label(currentModelTitle, systemImage: "cpu")
        }
        .help("Модель для этого чата: выбор провайдера и путь к настройкам ключей")
    }

    /// Название пункта меню модели с причиной недоступности.
    private func providerMenuTitle(_ descriptor: ProviderDescriptor) -> String {
        let name = descriptor.isLocal
            ? "\(descriptor.displayName) — локально"
            : descriptor.displayName
        var title = descriptor.defaultModel.map { "\(name) · \($0)" } ?? name
        if !viewModel.registry.isAvailable(descriptor.id) {
            title += descriptor.isLocal ? " (не запущен)" : " (нет ключа)"
        }
        return title
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

/// Попап тонких настроек RAG текущего чата (задача 23): topK, порог
/// близости, LLM-переранжирование и переписывание запроса.
struct RagTuningPopover: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Поиск по базе (RAG)")
                .font(.headline)
            Stepper("Фрагментов в контекст: \(viewModel.ragTopKBinding)",
                    value: Binding(get: { viewModel.ragTopKBinding },
                                   set: { viewModel.ragTopKBinding = $0 }),
                    in: ChatConfiguration.ragTopKRange)
                .help("Сколько найденных фрагментов vault уходит модели (topK)")
            VStack(alignment: .leading, spacing: 2) {
                Slider(value: Binding(get: { viewModel.ragMinScoreBinding },
                                      set: { viewModel.ragMinScoreBinding = ($0 * 20).rounded() / 20 }),
                       in: 0...1) {
                    Text("Мин. близость")
                }
                .help("Порог косинусной близости: фрагменты ниже порога отбрасываются")
                Text(viewModel.ragMinScoreBinding == 0
                     ? "Порог: выключен"
                     : String(format: "Порог: %.2f", viewModel.ragMinScoreBinding))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("LLM-переранжирование", isOn: Binding(
                get: { viewModel.ragRerankBinding },
                set: { viewModel.ragRerankBinding = $0 }))
                .help("Модель повторно сортирует кандидатов — точнее, но дополнительный вызов LLM")
            Toggle("Переписывать запрос", isOn: Binding(
                get: { viewModel.ragQueryRewriteBinding },
                set: { viewModel.ragQueryRewriteBinding = $0 }))
                .help("Вопрос переписывается в поисковый запрос — дополнительный вызов LLM")
            Text("Настройки сохраняются для этого чата.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Пузырь одного сообщения: markdown-рендер с кликабельными [[wikilinks]],
/// блок «Источники», метрики под ответом и hover-кнопка копирования.
struct MessageBubble: View {
    let message: ChatMessage
    var resolveWikilink: (String) -> URL? = { _ in nil }
    var openNote: (String) -> Void = { _ in }

    @State private var isHovering = false
    /// Кратковременный фидбек «скопировано» (галочка ~1 с).
    @State private var justCopied = false

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
        .overlay(alignment: .topTrailing) { copyButton }
        .onHover { isHovering = $0 }
    }

    /// Копирование сообщения (задача 23): сырой markdown в буфер обмена.
    @ViewBuilder
    private var copyButton: some View {
        if (isHovering || justCopied) && !message.content.isEmpty {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                justCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    justCopied = false
                }
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(justCopied ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Скопировать сообщение")
        }
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
