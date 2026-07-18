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
    /// Менеджер RAG-индекса (задача 28): чип «База» показывает состояние
    /// (нет эмбеддера / пусто / устарел / готов / индексация) и запускает
    /// индексацию прямо из чата.
    @ObservedObject var ragIndexManager: RagIndexManager
    /// Провайдер инструментов проекта (задача 31): число чанков индекса доков
    /// для чипа «База: Проект».
    let projectToolsProvider: ProjectToolsProvider
    /// Реестр баз знаний (задача 34): строки чипа «База» с мультивыбором.
    @ObservedObject var knowledgeBaseStore: KnowledgeBaseStore
    /// Фасад ретрива — статистика индексов папочных баз для чипа.
    let knowledgeBaseManager: KnowledgeBaseManager
    /// Кэш числа чанков доков (async-источник; обновляется task'ом ниже).
    @State private var projectDocsChunks: Int?
    /// Кэш числа чанков папочных баз по id (async-источник, задача 34).
    @State private var folderChunks: [String: Int] = [:]
    /// Доступные провайдеры с реальными моделями для пикера (задача 32).
    @State private var modelChoices: [ChatViewModel.ProviderModelChoices] = []
    /// Показ попапа настроек RAG (задача 23).
    @State private var showsRagTuning = false
    /// Открытие окна настроек из пикера модели (задача 24).
    @Environment(\.openSettings) private var openSettings
    /// Доступность провайдера (KeyStore/рантайм) не Combine-наблюдаема — тик
    /// по фокусу окна перечитывает её при возврате из настроек (задача 27;
    /// прецедент — keyChangeTick в ProvidersSettingsTab).
    @State private var availabilityTick = 0
    /// Редактор «своя модель per-чат» (задача 29). Поповер якорится к корню
    /// detail, НЕ к тулбар-кнопке: смена модели перерисовывает тайтл пикера
    /// и убила бы якорь (урок панели синка, задача 24).
    @State private var showsModelEditor = false
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

    /// Сводка чипа «База» (задачи 28, 31, 34): строки по глобально включённым
    /// базам реестра; availabilityTick — доступность эмбеддера перечитывается
    /// после возврата из настроек.
    private var ragChipSummary: RagChipSummary? {
        _ = availabilityTick
        let enabledIDs = chat?.configuration.enabledKnowledgeBaseIDs ?? []
        let embedderAvailable = ragIndexManager.currentEmbeddingTag() != nil
        let rows = knowledgeBaseStore.enabledBases.map { base -> KnowledgeBaseChipRow in
            let enabledInChat = enabledIDs.contains(base.id)
            switch base.kind {
            case .vault:
                return RagChipSummary.vaultRow(
                    base: base,
                    enabledInChat: enabledInChat,
                    embedderAvailable: embedderAvailable,
                    chunkCount: ragIndexManager.chunkCount,
                    indexTag: ragIndexManager.embeddingTag,
                    currentTag: ragIndexManager.currentEmbeddingTag()?.tag,
                    needsFullReindex: ragIndexManager.needsFullReindex,
                    isIndexing: ragIndexManager.progress != nil,
                    progressFraction: ragIndexManager.progress?.fraction)
            case .project:
                return RagChipSummary.projectRow(
                    base: base,
                    enabledInChat: enabledInChat,
                    projectRepo: ProjectRepoState.evaluate(
                        path: settingsStore.settings.projectRepoPath),
                    embedderAvailable: embedderAvailable,
                    docsChunks: projectDocsChunks)
            case .folder:
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: base.path,
                                                            isDirectory: &isDirectory)
                    && isDirectory.boolValue
                return RagChipSummary.folderRow(
                    base: base,
                    enabledInChat: enabledInChat,
                    folderExists: exists,
                    embedderAvailable: embedderAvailable,
                    chunks: folderChunks[base.id])
            }
        }
        return RagChipSummary.make(ragEnabled: chat?.configuration.ragEnabled ?? false,
                                   rows: rows)
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
            agentStatusBar
            errorBar
            inputBar
        }
        .navigationTitle(chat?.title ?? "Чат")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { agentModeToggle }
            ToolbarItem(placement: .primaryAction) { mcpMenu }
            ToolbarItem(placement: .primaryAction) { ragToggle }
            ToolbarItem(placement: .primaryAction) { ragTuningButton }
            ToolbarItem(placement: .primaryAction) { modelPicker }
        }
        // Превью постинга ревью в PR (задача 37): write-операция — только
        // после явного подтверждения в шите (правило бэклога №16).
        .sheet(item: $viewModel.reviewPostDialog) { context in
            ReviewPostSheet(viewModel: viewModel, context: context)
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
        // Число чанков индекса доков для чипа «База: Проект» (задача 31)
        // и список доступных моделей (задача 32); обновляется при смене
        // репо/чата/фокуса окна (availabilityTick ловит новые ключи/рантайм).
        .task(id: "\(availabilityTick)|\(settingsStore.settings.projectRepoPath)|\(chat?.id.uuidString ?? "")") {
            projectDocsChunks = await projectToolsProvider.docsChunkCount()
            modelChoices = await viewModel.availableModelChoices()
            // Чанки папочных баз для чипа (задача 34): ленивая статистика,
            // пустую БД ради неё не создаём.
            var chunks: [String: Int] = [:]
            for base in knowledgeBaseStore.enabledBases where base.kind == .folder {
                chunks[base.id] = await knowledgeBaseManager.folderService
                    .chunkCount(root: URL(fileURLWithPath: base.path))
            }
            folderChunks = chunks
        }
        // Редактор модели чата (задача 29) — якорь на корне detail.
        .popover(isPresented: $showsModelEditor,
                 attachmentAnchor: .point(.topTrailing),
                 arrowEdge: .bottom) {
            ChatModelEditor(viewModel: viewModel)
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

    /// Тумблер «Полный проход (FSM)» (задача 35, persisted per-чат):
    /// planning → execution → validation → answer вместо одного запроса.
    private var agentModeToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.agentModeBinding },
            set: { viewModel.agentModeBinding = $0 }
        )) {
            Label("Агент", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .toggleStyle(.button)
        .help("Полный проход (FSM): план → выполнение по шагам → проверка → ответ. Этапы приходят отдельными сообщениями, без стриминга. Выключено — один запрос.")
    }

    /// Статус-полоса активного FSM-прогона (задача 35): этап/шаг + управление.
    @ViewBuilder
    private var agentStatusBar: some View {
        if let chat, let ctx = chat.agentContext, ctx.status != .finished {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                Text(agentStatusLine(ctx))
                if ctx.status == .running {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if ctx.status == .running {
                    Button("Пауза") { viewModel.pauseAgentRun(chatID: chat.id) }
                        .help("Остановить прогон; «Продолжить» возобновит с того же шага")
                }
                if ctx.status == .paused || ctx.status == .failed {
                    Button("Продолжить") { viewModel.resumeAgentRun(chatID: chat.id) }
                        .help("Возобновить прогон с текущего этапа/шага")
                    Button("Сбросить") { viewModel.resetAgentRun(chatID: chat.id) }
                        .help("Забыть прогон; сообщения этапов останутся в истории")
                }
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.06))
        }
    }

    /// «Полный проход: Выполнение · шаг 2/5 (пауза)» — строка статус-полосы.
    private func agentStatusLine(_ ctx: AgentTaskContext) -> String {
        var line = "Полный проход: \(ctx.state.label)"
        if ctx.state == .execution, ctx.total > 0 {
            line += " · шаг \(min(ctx.step + 1, ctx.total))/\(ctx.total)"
        }
        switch ctx.status {
        case .running: break
        case .paused: line += " (пауза)"
        case .failed: line += " (ошибка)"
        case .finished: break
        }
        return line
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
                                      openNote: openNote,
                                      onPostReview: { viewModel.openReviewPostDialog(for: $0) })
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

    /// Чипы источников контекста (задачи 27, 28): «База» (RAG) первым, затем
    /// инструменты. Видно без единого клика; поповеры — статус и действия.
    @ViewBuilder
    private var toolChipsRow: some View {
        if ragChipSummary != nil || !toolSourceSummaries.isEmpty {
            HStack(spacing: 6) {
                if let ragSummary = ragChipSummary {
                    RagStatusChip(
                        summary: ragSummary,
                        onReindex: { full in ragIndexManager.reindex(fullRebuild: full) },
                        onOpenSettings: { tab in
                            SettingsTabRouter.open(tab, openSettings: { openSettings() })
                        },
                        onToggleBase: { viewModel.toggleKnowledgeBase($0) })
                }
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
                    guard let id = chat?.id else { return }
                    // FSM-прогон (задача 35): Стоп = пауза (возобновляемо).
                    if chat?.agentContext?.status == .running {
                        viewModel.pauseAgentRun(chatID: id)
                    } else {
                        viewModel.cancelGeneration(chatID: id)
                    }
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

    /// Пикер модели (задача 32): ТОЛЬКО доступные провайдеры и их реальные
    /// модели — Ollama показывает фактически установленные (из /api/tags),
    /// облако — актуальный список при наличии ключа. Нет ключа — провайдера
    /// в списке нет; «Добавить провайдера…» ведёт к ключам.
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
            ForEach(modelChoices) { choice in
                Section(choice.descriptor.isLocal
                        ? "\(choice.descriptor.displayName)"
                        : choice.descriptor.displayName) {
                    ForEach(choice.models, id: \.self) { model in
                        Button {
                            viewModel.setModel(providerID: choice.descriptor.id, model: model)
                        } label: {
                            let isCurrent = chat?.configuration.providerID == choice.descriptor.id
                                && chat?.configuration.model == model
                            if isCurrent {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Своя модель…") { showsModelEditor = true }
            Button("Добавить провайдера…") {
                SettingsTabRouter.open(.providers, openSettings: { openSettings() })
            }
            if modelChoices.isEmpty {
                Text("Нет доступных моделей: добавьте ключ («Провайдеры») или запустите Ollama.")
            }
        } label: {
            Label(currentModelTitle, systemImage: "cpu")
        }
        .help("Модель для этого чата: показаны только реально доступные")
    }

    private var currentModelTitle: String {
        guard let chat else { return "Модель" }
        if let providerID = chat.configuration.providerID {
            let name = viewModel.registry.descriptor(for: providerID)?.displayName
                ?? providerID.rawValue
            return chat.configuration.model.map { "\(name) · \($0)" } ?? name
        }
        // «Авто → реальный выбор роутера» (задача 29): видно, кто ответит.
        _ = availabilityTick
        return viewModel.resolvedAutoDescription.map { "Авто → \($0)" } ?? "Авто"
    }
}

/// Редактор «своя модель per-чат» (задача 29): провайдер + произвольная
/// строка модели (раньше можно было выбрать только дефолт провайдера).
struct ChatModelEditor: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var draftProviderID: ProviderID?
    @State private var draftModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Модель этого чата")
                .font(.headline)
            Picker("Провайдер", selection: $draftProviderID) {
                Text("Авто (роутер)").tag(ProviderID?.none)
                // Только доступные провайдеры (задача 32): нет ключа — нет пункта.
                ForEach(viewModel.chatProviderOptions
                    .filter { viewModel.registry.isAvailable($0.id) }) { descriptor in
                    Text(descriptor.displayName).tag(Optional(descriptor.id))
                }
            }
            TextField("Модель (например deepseek/deepseek-r1)", text: $draftModel)
                .textFieldStyle(.roundedBorder)
                .disabled(draftProviderID == nil)
                .help("Точное имя модели у провайдера; пусто — модель по умолчанию")
            HStack {
                Button("Сбросить на дефолт") {
                    viewModel.setModel(providerID: nil, model: nil)
                    dismiss()
                }
                Spacer()
                Button("Применить") {
                    let model = draftModel.trimmingCharacters(in: .whitespaces)
                    viewModel.setModel(providerID: draftProviderID,
                                       model: model.isEmpty ? nil : model)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            draftProviderID = viewModel.selectedChat?.configuration.providerID
            draftModel = viewModel.selectedChat?.configuration.model ?? ""
        }
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
            Toggle("RAG как инструмент (rag_search)", isOn: Binding(
                get: { viewModel.ragAsToolBinding },
                set: { viewModel.ragAsToolBinding = $0 }))
                .help("Модель сама вызывает поиск по включённым базам (нужен function calling; ответ приходит без стриминга). Выключено — контекст подставляется автоматически.")
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
    /// Постинг ревью в PR (задача 37): кнопка видна при message.reviewTarget.
    var onPostReview: ((ChatMessage) -> Void)? = nil

    @State private var isHovering = false
    /// Кратковременный фидбек «скопировано» (галочка ~1 с).
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(message.role == .user ? "Вы" : "Ассистент")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                agentBadge
                reviewVerdictBadge
            }
            toolCallsBlock
            Markdown(renderedContent)
                .markdownTheme(.docC)
                .textSelection(.enabled)
            sourcesBlock
            if let metrics = message.metrics {
                Text(metricsLine(metrics))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(metricsTooltip(metrics) ?? "")
            }
            reviewPostRow
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

    /// Бейдж этапа FSM-прогона (задача 35): «Планирование», «Выполнение ·
    /// шаг N/M», «Проверка», «Ответ» — цвет по этапу.
    @ViewBuilder
    private var agentBadge: some View {
        if let state = message.agentState {
            Text(agentBadgeText(state))
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(agentBadgeColor(state).opacity(0.15)))
                .foregroundStyle(agentBadgeColor(state))
        }
    }

    private func agentBadgeText(_ state: AgentTaskState) -> String {
        guard state == .execution, let step = message.agentStep,
              let total = message.agentTotal, total > 0 else { return state.label }
        return "\(state.label) · шаг \(step + 1)/\(total)"
    }

    private func agentBadgeColor(_ state: AgentTaskState) -> Color {
        switch state {
        case .planning: return .blue
        case .execution: return .orange
        case .validation: return .purple
        case .answer: return .green
        }
    }

    /// Бейдж вердикта ревью (задача 37): вычисляется из content — маркер
    /// «ИТОГ РЕВЬЮ:» ставит сама модель, персистить нечего.
    @ViewBuilder
    private var reviewVerdictBadge: some View {
        if message.reviewTarget != nil,
           let verdict = CodeReviewPrompts.parseVerdict(message.content) {
            let approve = verdict == .approve
            Text(approve ? "APPROVE" : "Нужны правки")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill((approve ? Color.green : .orange).opacity(0.15)))
                .foregroundStyle(approve ? Color.green : .orange)
        }
    }

    /// Действие «Отправить комментарием в PR» (задача 37) под итогом ревью;
    /// после успешного постинга — персистентная метка «Отправлено ✓».
    @ViewBuilder
    private var reviewPostRow: some View {
        if let target = message.reviewTarget {
            if let postedAt = message.reviewPostedAt {
                Label("Отправлено в PR #\(String(target.number)) · \(postedAt.formatted(date: .abbreviated, time: .shortened))",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let onPostReview {
                Button {
                    onPostReview(message)
                } label: {
                    Label("Отправить комментарием в PR #\(String(target.number))",
                          systemImage: "paperplane")
                }
                .controlSize(.small)
                .help("Превью и подтверждение перед отправкой на GitHub")
            }
        }
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

    /// «Провайдер · модель · 1.2 с · 850 ток.» — кто и почём ответил (задача 29).
    private func metricsLine(_ metrics: MessageMetrics) -> String {
        var parts: [String] = []
        if let name = metrics.providerName { parts.append(name) }
        if let model = metrics.model { parts.append(model) }
        parts.append(String(format: "%.1f c", metrics.duration))
        if let total = metrics.totalTokens { parts.append("\(total) ток.") }
        return parts.joined(separator: " · ")
    }

    /// Разбивка токенов для тултипа метрик; nil — usage не пришёл.
    private func metricsTooltip(_ metrics: MessageMetrics) -> String? {
        guard let prompt = metrics.promptTokens,
              let completion = metrics.completionTokens else { return nil }
        return "промпт: \(prompt) ток. · ответ: \(completion) ток."
    }
}

// MARK: - Превью постинга ревью в PR (задача 37)

/// Редактируемое превью + явное подтверждение перед POST-комментарием
/// (паттерн TitleConfirmationView встреч; правило бэклога №16 о write-
/// операциях). Ошибка отправки показывается здесь же — шит не закрывается.
struct ReviewPostSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    let context: ChatViewModel.ReviewPostContext

    @State private var commentBody: String
    @State private var errorText: String?
    @State private var isPosting = false

    init(viewModel: ChatViewModel, context: ChatViewModel.ReviewPostContext) {
        self.viewModel = viewModel
        self.context = context
        _commentBody = State(initialValue: context.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Комментарий в PR #\(String(context.target.number)) — \(context.target.owner)/\(context.target.repo)")
                .font(.headline)
            TextEditor(text: $commentBody)
                .font(.body.monospaced())
                .frame(minWidth: 480, minHeight: 240)
            if !viewModel.reviewPostTokenAvailable {
                Label("Нужен GitHub-токен с правом записи — Настройки → «Инструменты».",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorText {
                Label(errorText, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Отмена") { viewModel.reviewPostDialog = nil }
                Button(isPosting ? "Отправка…" : "Отправить в PR #\(String(context.target.number))") {
                    isPosting = true
                    errorText = nil
                    Task {
                        // nil = успех (диалог уже закрыт submitReviewPost'ом).
                        errorText = await viewModel.submitReviewPost(body: commentBody,
                                                                     context: context)
                        isPosting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPosting
                          || !viewModel.reviewPostTokenAvailable
                          || commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }
}
