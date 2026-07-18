// PipelineViews.swift — UI раздела «Пайплайны» (задача 36).
//
// Средняя колонка — PipelinesPane: список конфигов (toggle enabled, «Запустить»,
// статус/время последнего прогона, бейдж ошибки PR-watch). Detail —
// PipelineDetailView: Form-редактор конфига (триггер с полями по типу, промпт,
// выбор инструментов/баз/чата-назначения, режим агента, провайдер/модель)
// + история прогонов выбранного пайплайна с переходом в destination-чат.
// Палитра статусов — как в MA RoutinesPanelView: ok=green, running=blue,
// error=red, skipped/missed=orange.

import SwiftUI

extension Notification.Name {
    /// «Открыть чат» из истории прогонов: object — UUID destination-чата.
    static let openPipelineChat = Notification.Name("openPipelineChat")
}

// MARK: - Список (средняя колонка)

struct PipelinesPane: View {
    @ObservedObject var store: PipelineStore
    let engine: PipelineEngine
    @ObservedObject var watcher: PRWatcher

    var body: some View {
        List(selection: $store.selectedPipelineID) {
            if store.pipelines.isEmpty {
                Text("Пайплайнов пока нет. Нажмите «+».")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.pipelines) { pipeline in
                row(pipeline)
                    .tag(pipeline.id)
                    .contextMenu {
                        Button("Запустить") { runNow(pipeline) }
                        Button(role: .destructive) {
                            store.remove(id: pipeline.id)
                        } label: {
                            Label("Удалить пайплайн", systemImage: "trash")
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let pipeline = PipelineConfig()
                    store.add(pipeline)
                    store.selectedPipelineID = pipeline.id
                } label: {
                    Label("Новый пайплайн", systemImage: "plus")
                }
                .help("Новый пайплайн")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let preset = PipelineConfig.codeReviewPreset()
                    store.add(preset)
                    store.selectedPipelineID = preset.id
                } label: {
                    Label("Добавить Code Review", systemImage: "checkmark.seal")
                }
                .help("Пресет Code Review: ревью новых PR выбранного репозитория")
            }
        }
    }

    @ViewBuilder
    private func row(_ pipeline: PipelineConfig) -> some View {
        let latest = store.latestRun(pipelineID: pipeline.id)
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { store.pipeline(id: pipeline.id)?.enabled ?? false },
                set: { enabled in store.mutate(id: pipeline.id) { $0.enabled = enabled } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(pipeline.enabled ? "Выключить" : "Включить")
            VStack(alignment: .leading, spacing: 2) {
                Text(pipeline.name).lineLimit(1)
                HStack(spacing: 4) {
                    Text(pipeline.trigger.summary)
                    if let error = watcher.runtimeByPipeline[pipeline.id]?.lastError {
                        Label("сеть", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(error)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let latest {
                PipelineRunStatusBadge(run: latest)
            }
            Button {
                runNow(pipeline)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .help("Запустить сейчас")
        }
        .padding(.vertical, 2)
    }

    private func runNow(_ pipeline: PipelineConfig) {
        Task { await engine.run(pipeline, trigger: .manual) }
    }
}

/// Цветная точка + время последнего прогона (палитра MA).
struct PipelineRunStatusBadge: View {
    let run: PipelineRun

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(run.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("\(run.status.title) · \(run.trigger.title)")
    }

    private var color: Color {
        switch run.status {
        case .ok: return .green
        case .running: return .blue
        case .error: return .red
        case .skippedOverlap, .missed: return .orange
        }
    }
}

// MARK: - Detail: редактор + история

struct PipelineDetailView: View {
    @ObservedObject var store: PipelineStore
    let engine: PipelineEngine
    @ObservedObject var watcher: PRWatcher
    @ObservedObject var chatViewModel: ChatViewModel
    @ObservedObject var mcpViewModel: MCPServersViewModel
    @ObservedObject var knowledgeBaseStore: KnowledgeBaseStore

    var body: some View {
        if let id = store.selectedPipelineID,
           let index = store.pipelines.firstIndex(where: { $0.id == id }) {
            PipelineEditorForm(pipeline: $store.pipelines[index],
                               store: store,
                               engine: engine,
                               watcher: watcher,
                               chatViewModel: chatViewModel,
                               mcpViewModel: mcpViewModel,
                               knowledgeBaseStore: knowledgeBaseStore)
                .id(id) // смена выбора пересоздаёт форму (сбрасывает @State)
        } else {
            ContentUnavailableView(
                "Пайплайн не выбран",
                systemImage: "gearshape.arrow.triangle.2.circlepath",
                description: Text("Выберите пайплайн в списке слева или создайте новый.")
            )
        }
    }
}

/// Форма редактора конфига. Правки пишутся прямо в биндинг стора (debounce-
/// автосейв), «Запустить» гоняет движок с ручным триггером.
private struct PipelineEditorForm: View {
    @Binding var pipeline: PipelineConfig
    @ObservedObject var store: PipelineStore
    let engine: PipelineEngine
    @ObservedObject var watcher: PRWatcher
    @ObservedObject var chatViewModel: ChatViewModel
    @ObservedObject var mcpViewModel: MCPServersViewModel
    @ObservedObject var knowledgeBaseStore: KnowledgeBaseStore

    /// Пресеты cron — самые ходовые расписания (эталон RoutineEditorView MA).
    private static let cronPresets: [(String, String)] = [
        ("Каждый день 09:00", "0 9 * * *"),
        ("По будням 09:00", "0 9 * * 1-5"),
        ("Каждый час", "0 * * * *"),
        ("Каждые 15 мин", "*/15 * * * *"),
    ]

    var body: some View {
        Form {
            Section("Пайплайн") {
                TextField("Название", text: $pipeline.name)
                Toggle("Включён", isOn: $pipeline.enabled)
                if pipeline.preset == .codeReview {
                    Text("Пресет Code Review: input прогона (diff PR, документация, тесты) собирается автоматически — промпт ниже не используется.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            triggerSection
            if pipeline.preset != .codeReview {
                Section("Промпт") {
                    TextEditor(text: $pipeline.inputTemplate)
                        .font(.body.monospaced())
                        .frame(minHeight: 88)
                    Text("Плейсхолдеры: {{trigger_payload}} — полезная нагрузка триггера (данные PR), {{date}} — сегодняшняя дата.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            agentSection
            toolsSection
            outputSection
            historySection
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let snapshot = pipeline
                    Task { await engine.run(snapshot, trigger: .manual) }
                } label: {
                    Label("Запустить", systemImage: "play.fill")
                }
                .help("Запустить сейчас (ручной триггер)")
            }
        }
    }

    // MARK: Триггер

    /// Биндинг «тип триггера» поверх enum с ассоциированными значениями.
    private var triggerKind: Binding<String> {
        Binding(
            get: {
                switch pipeline.trigger {
                case .manual: return "manual"
                case .cron: return "cron"
                case .prWatch: return "prWatch"
                }
            },
            set: { kind in
                switch kind {
                case "cron": pipeline.trigger = .cron(expression: "0 9 * * *")
                case "prWatch":
                    pipeline.trigger = .prWatch(
                        owner: "", repo: "",
                        pollIntervalMin: PipelineTrigger.minPollIntervalMin)
                default: pipeline.trigger = .manual
                }
            })
    }

    @ViewBuilder
    private var triggerSection: some View {
        Section("Триггер") {
            Picker("Тип", selection: triggerKind) {
                Text("Ручной").tag("manual")
                Text("Расписание (cron)").tag("cron")
                Text("Новые PR на GitHub").tag("prWatch")
            }
            .pickerStyle(.segmented)

            switch pipeline.trigger {
            case .manual:
                Text("Запуск только кнопкой «Запустить».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .cron(let expression):
                cronFields(expression)
            case .prWatch(let owner, let repo, let interval):
                prWatchFields(owner: owner, repo: repo, interval: interval)
            }
        }
    }

    @ViewBuilder
    private func cronFields(_ expression: String) -> some View {
        TextField("Cron-выражение", text: Binding(
            get: { expression },
            set: { pipeline.trigger = .cron(expression: $0) }))
            .font(.body.monospaced())
        HStack {
            ForEach(Self.cronPresets, id: \.1) { preset in
                Button(preset.0) { pipeline.trigger = .cron(expression: preset.1) }
                    .controlSize(.small)
            }
        }
        // Живая валидация: невалидное выражение — сразу видно, валидное —
        // показывает ближайшее срабатывание.
        if let cron = CronExpression.parse(expression) {
            if let next = cron.nextDate(after: Date()) {
                Text("Следующий запуск: \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Выражение никогда не сработает")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Невалидное выражение. Формат: минута час день месяц день-недели (напр. */15 * * * *)")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func prWatchFields(owner: String, repo: String, interval: Int) -> some View {
        TextField("Владелец (owner)", text: Binding(
            get: { owner },
            set: { pipeline.trigger = .prWatch(owner: $0.trimmingCharacters(in: .whitespaces),
                                               repo: repo, pollIntervalMin: interval) }))
        TextField("Репозиторий", text: Binding(
            get: { repo },
            set: { pipeline.trigger = .prWatch(owner: owner,
                                               repo: $0.trimmingCharacters(in: .whitespaces),
                                               pollIntervalMin: interval) }))
        Stepper(value: Binding(
            get: { interval },
            set: { pipeline.trigger = .prWatch(owner: owner, repo: repo,
                                               pollIntervalMin: $0) }),
                in: PipelineTrigger.minPollIntervalMin...120) {
            Text("Опрос каждые \(interval) мин")
        }
        HStack(spacing: 8) {
            if let remaining = watcher.runtimeByPipeline[pipeline.id]?.rateLimitRemaining {
                Text("Лимит GitHub: осталось \(remaining) запросов")
            } else {
                Text("Без токена лимит GitHub — 60 запросов/час (токен — Настройки → «Инструменты»)")
            }
            if let error = watcher.runtimeByPipeline[pipeline.id]?.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Агент и инструменты

    @ViewBuilder
    private var agentSection: some View {
        Section("Агент") {
            Picker("Режим", selection: $pipeline.agentMode) {
                Text("Полный проход (FSM)").tag(PipelineAgentMode.fsm)
                Text("Один запрос").tag(PipelineAgentMode.single)
            }
            .pickerStyle(.segmented)
            Picker("Провайдер", selection: $pipeline.providerID) {
                Text("Авто (роутер)").tag(ProviderID?.none)
                ForEach(chatViewModel.chatProviderOptions) { descriptor in
                    Text(descriptor.displayName).tag(ProviderID?.some(descriptor.id))
                }
            }
            if pipeline.providerID != nil {
                TextField("Модель (пусто — модель провайдера по умолчанию)",
                          text: Binding(
                            get: { pipeline.model ?? "" },
                            set: { pipeline.model = $0.isEmpty ? nil : $0 }))
            }
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        Section("Инструменты и знания") {
            Toggle("Инструменты проекта (git)", isOn: $pipeline.projectToolsEnabled)
            if mcpViewModel.servers.isEmpty {
                Text("MCP-серверы не настроены (Настройки → «Инструменты»)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mcpViewModel.servers) { server in
                    Toggle("MCP: \(server.name)", isOn: Binding(
                        get: { pipeline.enabledMCPServerIDs.contains(server.id) },
                        set: { on in
                            if on { pipeline.enabledMCPServerIDs.insert(server.id) }
                            else { pipeline.enabledMCPServerIDs.remove(server.id) }
                        }))
                }
            }
            ForEach(knowledgeBaseStore.bases) { base in
                Toggle("База: \(base.name)", isOn: Binding(
                    get: { pipeline.enabledKnowledgeBaseIDs.contains(base.id) },
                    set: { on in
                        if on { pipeline.enabledKnowledgeBaseIDs.insert(base.id) }
                        else { pipeline.enabledKnowledgeBaseIDs.remove(base.id) }
                    }))
            }
            Text("Выбранные базы дают агенту rag_search; пусто — прогон без RAG.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Вывод и история

    @ViewBuilder
    private var outputSection: some View {
        Section("Вывод") {
            Picker("Чат назначения", selection: $pipeline.destinationChatID) {
                Text("Автоматически («Пайплайн: \(pipeline.name)»)").tag(UUID?.none)
                ForEach(chatViewModel.chats) { chat in
                    Text(chat.title).tag(UUID?.some(chat.id))
                }
            }
            if case .cron = pipeline.trigger {
                Toggle("Догонять пропущенный слот при старте", isOn: $pipeline.catchUpOnStart)
            }
            if pipeline.preset == .codeReview {
                // Write-операция: default выкл, постинг строго после успешного
                // терминала FSM (правило бэклога №16).
                Toggle("Постить ревью комментарием в PR автоматически",
                       isOn: $pipeline.autoPostReviewComment)
                Text("Нужен GitHub-токен с правом записи (Настройки → «Инструменты»). Без автопоста ревью отправляется кнопкой под сообщением.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let runs = store.runs.filter { $0.pipelineID == pipeline.id }
        Section("История прогонов") {
            if runs.isEmpty {
                Text("Прогонов ещё не было.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(runs) { run in
                PipelineRunRow(run: run)
            }
        }
    }
}

/// Строка истории: статус, триггер, время, токены, ошибка, переход в чат.
struct PipelineRunRow: View {
    let run: PipelineRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                PipelineRunStatusBadge(run: run)
                Text(run.status.title)
                    .font(.caption)
                Text(run.trigger.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let total = run.totalTokens {
                    Text("\(total) ткн")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let chatID = run.destinationChatID, run.status != .missed {
                    Button("Открыть чат") {
                        NotificationCenter.default.post(name: .openPipelineChat,
                                                        object: chatID)
                    }
                    .controlSize(.small)
                }
            }
            if let payload = run.payloadSummary?.split(whereSeparator: \.isNewline).first {
                Text(String(payload))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let error = run.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(run.status == .error ? .red : .orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
