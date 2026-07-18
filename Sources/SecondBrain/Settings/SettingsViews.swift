// SettingsViews.swift — окно Settings (Cmd+,) со вкладками (задача 17).
//
// Вкладки: Общие (vault + RAG-индекс), Провайдеры (ключи), Модели (роутинг
// функция → провайдер+модель), Встречи (промпт раскладки, папка/источник по
// умолчанию), Локальные модели (Ollama/Whisper/idle), Инструменты (репозиторий
// проекта + встроенные инструменты + MCP-серверы, задача 27), Синхронизация.
// Всё «настраиваемое» сведено сюда, ничего не потеряно.
//
// View только читают сторы/вью-модели из AppModel; логика — в них.

import AppKit
import SwiftUI

/// Вкладки окна настроек. rawValue — контракт нотификации openSettingsTab.
enum SettingsTab: String, CaseIterable {
    case general, providers, models, meetings, localModels, tools, sync
}

extension Notification.Name {
    /// «Открыть настройки на вкладке» (object — SettingsTab). Шлют чипы чата,
    /// мастер и пункт «Добавить инструменты…» (задача 27).
    static let openSettingsTab = Notification.Name("com.local.second-brain.openSettingsTab")
}

/// Открытие окна настроек на нужной вкладке. Два канала: при ПЕРВОМ открытии
/// окна SettingsRootView ещё не существует в момент openSettings() и
/// нотификацию никто не слышит — pending добирается в onAppear; нотификация
/// покрывает уже открытое окно.
@MainActor
enum SettingsTabRouter {
    private(set) static var pending: SettingsTab?

    /// openSettings — замыкание (а не OpenSettingsAction), чтобы роутер
    /// тестировался без SwiftUI-окружения.
    static func open(_ tab: SettingsTab, openSettings: () -> Void) {
        pending = tab
        openSettings()
        NotificationCenter.default.post(name: .openSettingsTab, object: tab)
    }

    /// Однократный забор отложенной вкладки (SettingsRootView.onAppear).
    static func consumePending() -> SettingsTab? {
        defer { pending = nil }
        return pending
    }
}

/// Корень окна настроек: TabView со стандартными тулбар-вкладками macOS.
struct SettingsRootView: View {
    let model: AppModel
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab(store: model.settingsStore,
                               vaultManager: model.vaultManager,
                               ragManager: model.ragIndexManager)
                .tabItem { Label("Общие", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ProvidersSettingsTab(registry: model.providerRegistry)
                .tabItem { Label("Провайдеры", systemImage: "key") }
                .tag(SettingsTab.providers)
            ModelsSettingsTab(router: model.functionRouter,
                              registry: model.providerRegistry)
                .tabItem { Label("Модели", systemImage: "cpu") }
                .tag(SettingsTab.models)
            MeetingsSettingsTab(meetingsViewModel: model.meetingsViewModel)
                .tabItem { Label("Встречи", systemImage: "mic") }
                .tag(SettingsTab.meetings)
            LocalModelsPane(viewModel: model.localModelsViewModel,
                            manager: model.ollamaManager,
                            whisperViewModel: model.whisperModelsViewModel,
                            settingsStore: model.settingsStore)
                .tabItem { Label("Локальные модели", systemImage: "desktopcomputer") }
                .tag(SettingsTab.localModels)
            ToolsSettingsTab(viewModel: model.mcpServersViewModel,
                             settingsStore: model.settingsStore,
                             vaultManager: model.vaultManager,
                             projectToolsProvider: model.projectToolsProvider,
                             knowledgeBaseStore: model.knowledgeBaseStore,
                             knowledgeBaseManager: model.knowledgeBaseManager)
                .tabItem { Label("Инструменты", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.tools)
            SyncSettingsTab(store: model.settingsStore, syncViewModel: model.syncViewModel)
                .tabItem { Label("Синхронизация", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.sync)
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear {
            if let tab = SettingsTabRouter.consumePending() { selection = tab }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { note in
            if let tab = note.object as? SettingsTab { selection = tab }
        }
    }
}

// MARK: - Общие

struct GeneralSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var ragManager: RagIndexManager

    var body: some View {
        Form {
            Section("Vault") {
                HStack {
                    Text("Текущий")
                    Spacer()
                    Text(vaultManager.vaultURL?.path ?? "не открыт")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Сменить vault…") { vaultManager.openVaultPanel() }
                    if !vaultManager.recentVaults.isEmpty {
                        Menu("Недавние") {
                            ForEach(vaultManager.recentVaults) { recent in
                                Button(recent.name) { vaultManager.openRecent(recent) }
                                    .help(recent.path)
                            }
                        }
                        .fixedSize()
                    }
                }
                Toggle("Показывать скрытые папки (.obsidian, .git…)",
                       isOn: $vaultManager.showsDotItems)
                Toggle("Открывать последний vault при запуске",
                       isOn: $store.settings.restoreLastVault)
            }
            // RAG-индекс vault (задача 13) — переехал из бывшего раздела настроек.
            RagStatusSection(manager: ragManager)
            // Секция «Инструменты проекта» переехала на вкладку «Инструменты»
            // (задача 27) — единая точка настройки туллинга.
        }
        .formStyle(.grouped)
    }
}

/// NSOpenPanel выбора корня репозитория; общий для вкладки «Инструменты»
/// и мастера в пустом чате (задача 27).
@MainActor
enum ProjectRepoPicker {
    static func pick(into store: SettingsStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.message = "Выберите корень git-репозитория проекта"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.projectRepoPath = url.path
    }
}

// MARK: - Провайдеры (ключи)

struct ProvidersSettingsTab: View {
    @ObservedObject var registry: ProviderRegistry

    /// Черновики вводимых ключей и результаты проверки — по провайдеру.
    @State private var drafts: [ProviderID: String] = [:]
    @State private var verdicts: [ProviderID: KeyVerifier.Verdict] = [:]
    @State private var verifying: ProviderID?
    /// Тик для перерисовки статуса «ключ задан» после записи в Keychain
    /// (KeyStore — не ObservableObject).
    @State private var keyChangeTick = 0

    var body: some View {
        Form {
            Section {
                ForEach(registry.descriptors.filter(\.requiresKey)) { descriptor in
                    providerRow(descriptor)
                }
            } footer: {
                Text("Ключи хранятся в Keychain и никогда не показываются. Переменная окружения SECONDBRAIN_<ID>_KEY имеет приоритет (для разработки). Локальные провайдеры (Ollama, WhisperKit) ключей не требуют — они на вкладке «Локальные модели».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func providerRow(_ descriptor: ProviderDescriptor) -> some View {
        let hasKey = keyChangeTick >= 0 && KeyStore.hasKey(for: descriptor.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(descriptor.displayName)
                    .fontWeight(.medium)
                Spacer()
                Label(hasKey ? "ключ задан" : "ключа нет",
                      systemImage: hasKey ? "checkmark.circle" : "circle")
                    .font(.caption)
                    .foregroundStyle(hasKey ? .green : .secondary)
            }
            HStack {
                SecureField("Новый ключ", text: draftBinding(descriptor.id))
                    .textFieldStyle(.roundedBorder)
                Button("Сохранить") {
                    KeyStore.setKey(drafts[descriptor.id] ?? "", for: descriptor.id)
                    drafts[descriptor.id] = ""
                    verdicts[descriptor.id] = nil
                    keyChangeTick += 1
                }
                .disabled((drafts[descriptor.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                if hasKey {
                    Button("Удалить", role: .destructive) {
                        KeyStore.setKey("", for: descriptor.id)
                        verdicts[descriptor.id] = nil
                        keyChangeTick += 1
                    }
                    if verifying == descriptor.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Проверить") { verify(descriptor.id) }
                    }
                }
            }
            if let verdict = verdicts[descriptor.id] {
                Label(verdict.label,
                      systemImage: verdict == .ok ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(verdict == .ok ? .green : .orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func draftBinding(_ id: ProviderID) -> Binding<String> {
        Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 })
    }

    /// Лёгкий запрос к API — принят ли ключ (KeyVerifier).
    private func verify(_ id: ProviderID) {
        guard verifying == nil, let key = KeyStore.key(for: id) else { return }
        verifying = id
        Task {
            let verdict = await KeyVerifier.verify(id: id, key: key)
            verdicts[id] = verdict
            verifying = nil
        }
    }
}

// MARK: - Модели (роутинг)

struct ModelsSettingsTab: View {
    @ObservedObject var router: FunctionRouter
    @ObservedObject var registry: ProviderRegistry

    /// Метка «Авто» в пикере провайдера (нет явного назначения).
    private static let autoTag: ProviderID? = nil

    var body: some View {
        Form {
            Section {
                ForEach(AppFunction.allCases, id: \.rawValue) { function in
                    functionRow(function)
                }
            } footer: {
                Text("«Авто» — первый доступный провайдер нужного типа. Явное назначение действует, пока провайдер доступен; иначе прозрачно работает автодефолт (строка с предупреждением).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func functionRow(_ function: AppFunction) -> some View {
        let issue = RoutingValidator.issues(config: router.config, registry: registry)
            .first { $0.function == function }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(function.displayName, selection: providerBinding(function)) {
                    Text("Авто").tag(Self.autoTag)
                    ForEach(registry.descriptors(supporting: function.requiredCapability)) { descriptor in
                        Text(descriptor.displayName).tag(Optional(descriptor.id))
                    }
                }
                if router.assignment(for: function) != nil {
                    TextField("модель", text: modelBinding(function))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }
            if let issue {
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    /// Пикер провайдера: nil — «Авто» (снять назначение).
    private func providerBinding(_ function: AppFunction) -> Binding<ProviderID?> {
        Binding(
            get: { router.assignment(for: function)?.providerID },
            set: { newID in
                guard let newID else {
                    router.clearAssignment(for: function)
                    return
                }
                // Модель — прежняя (если менялся только провайдер, обычно
                // нужна свежая), иначе дефолтная провайдера.
                let model = registry.descriptor(for: newID)?
                    .defaultModel(for: function.requiredCapability) ?? ""
                router.assign(FunctionAssignment(providerID: newID, model: model), to: function)
            }
        )
    }

    private func modelBinding(_ function: AppFunction) -> Binding<String> {
        Binding(
            get: { router.assignment(for: function)?.model ?? "" },
            set: { newModel in
                guard var assignment = router.assignment(for: function) else { return }
                assignment.model = newModel
                router.assign(assignment, to: function)
            }
        )
    }
}

// MARK: - Встречи

struct MeetingsSettingsTab: View {
    /// Правила раскладки редактируются через MeetingsViewModel — он уже
    /// владеет этим полем (и его же показывает раздел «Встречи»).
    @ObservedObject var meetingsViewModel: MeetingsViewModel

    /// Остальные поля MeetingSettings — локальные черновики; запись через
    /// load-modify-save (MeetingSettingsStore.update), чтобы не стирать чужое.
    @State private var defaultFolder = ""
    @State private var defaultSource: RecordingSource = .microphone

    var body: some View {
        Form {
            Section("Правила раскладки для LLM") {
                TextEditor(text: $meetingsViewModel.filingRules)
                    .font(.callout)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if meetingsViewModel.filingRules.isEmpty {
                            Text("Например: «встречи 1:1 клади в Управление командой/1на1». Пусто — заметки идут в папку по умолчанию.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                Button("Сбросить к дефолту") { meetingsViewModel.filingRules = "" }
                    .disabled(meetingsViewModel.filingRules.isEmpty)
            }
            Section("По умолчанию") {
                TextField("Папка заметок встреч", text: $defaultFolder,
                          prompt: Text("Meetings/YYYY-MM (штатная)"))
                    .onChange(of: defaultFolder) { _, folder in
                        MeetingSettingsStore.update { $0.defaultFolder = folder }
                    }
                Picker("Источник записи", selection: $defaultSource) {
                    ForEach(RecordingSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .onChange(of: defaultSource) { _, source in
                    MeetingSettingsStore.update { $0.defaultSource = source }
                    meetingsViewModel.sourceChoice = source
                }
                Text("Папка используется, когда LLM не предложил валидную; источник — предвыбор при старте записи.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Полные статусы разрешений переехали сюда из раздела «Встречи»
            // (задача 41): в разделе — только предупреждения, когда что-то
            // реально мешает записи.
            Section("Разрешения") {
                PermissionRow(
                    granted: meetingsViewModel.micAuthorized,
                    grantedText: "Микрофон: разрешён",
                    deniedText: "Микрофон: запрещён (Системные настройки → Конфиденциальность)",
                    unknownText: "Микрофон: разрешение запросим при первой записи")
                PermissionRow(
                    granted: MeetingsViewModel.systemAudioSupported ? nil : false,
                    grantedText: "",
                    deniedText: "Системный звук: требуется macOS 14.4+",
                    unknownText: "Системный звук: разрешение запросит macOS при первой записи")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let settings = MeetingSettingsStore.load()
            defaultFolder = settings.defaultFolder
            // Не задан — «оба входа» (задача 41), с деградацией на старых macOS.
            defaultSource = settings.resolvedDefaultSource(
                systemAudioSupported: MeetingsViewModel.systemAudioSupported)
        }
    }
}

// MARK: - Инструменты

/// Вкладка «Инструменты» (задача 27): единая точка настройки туллинга —
/// репозиторий проекта (переехал из «Общих») + каталог встроенных
/// инструментов + MCP-серверы (бывшая вкладка MCP).
struct ToolsSettingsTab: View {
    @ObservedObject var viewModel: MCPServersViewModel
    @ObservedObject var settingsStore: SettingsStore
    /// Для кнопки «Текущий vault».
    @ObservedObject var vaultManager: VaultManager
    /// Статус RAG-индекса документации проекта (задача 28).
    let projectToolsProvider: ProjectToolsProvider
    /// Реестр баз знаний (задача 34): секция управления папочными базами.
    @ObservedObject var knowledgeBaseStore: KnowledgeBaseStore
    let knowledgeBaseManager: KnowledgeBaseManager

    /// Предупреждение «выбранная папка — не git-репозиторий» (не блокирует:
    /// list_files/read_file работают и без git).
    @State private var projectRepoWarning: String?
    /// Статистика индекса доков; nil — не строился или репозиторий не выбран.
    @State private var docsStats: ProjectDocsIndexService.DocsIndexStats?

    /// Каталог встроенных инструментов статичен — считается один раз.
    private static let builtinCatalog = ToolRegistry.projectToolCatalog()

    var body: some View {
        Form {
            builtinToolsSection
            KnowledgeBasesSection(store: knowledgeBaseStore,
                                  folderService: knowledgeBaseManager.folderService)
            MCPServersSection(viewModel: viewModel,
                              projectRepoPath: settingsStore.settings.projectRepoPath)
            GitHubTokenSection()
        }
        .formStyle(.grouped)
        // Проверка «папка — git-репозиторий?» + статистика индекса доков
        // при каждом изменении пути.
        .task(id: settingsStore.settings.projectRepoPath) {
            await refreshProjectRepoWarning()
            docsStats = await projectToolsProvider.docsIndexStats()
        }
    }

    /// Строка статуса RAG-индекса документации (задача 28): доки индексируются
    /// лениво при /help — здесь только наблюдение и сброс.
    @ViewBuilder
    private var docsIndexRow: some View {
        if !settingsStore.settings.projectRepoPath.isEmpty {
            HStack {
                if let stats = docsStats {
                    Text(Self.docsStatsLine(stats))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Сбросить индекс") {
                        Task {
                            await projectToolsProvider.resetDocsIndex()
                            docsStats = await projectToolsProvider.docsIndexStats()
                        }
                    }
                    .controlSize(.small)
                    .help("Индекс перестроится при следующем /help")
                } else {
                    Text("RAG по документации: индекс построится при первом /help (нужна модель эмбеддингов)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func docsStatsLine(_ stats: ProjectDocsIndexService.DocsIndexStats) -> String {
        var line = "RAG по документации: \(stats.files) файлов · \(stats.chunks) чанков"
        if let updated = stats.updatedAt {
            line += " · обновлён " + updated.formatted(date: .abbreviated, time: .shortened)
        }
        return line
    }

    private var builtinToolsSection: some View {
        Section("Встроенные инструменты проекта") {
            HStack {
                Text("Репозиторий")
                Spacer()
                Text(settingsStore.settings.projectRepoPath.isEmpty
                     ? "не выбран" : settingsStore.settings.projectRepoPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Выбрать…") { ProjectRepoPicker.pick(into: settingsStore) }
                    .help("Выбрать папку git-репозитория, по которому ассистент сможет ходить")
                Button("Текущий vault") {
                    settingsStore.settings.projectRepoPath = vaultManager.vaultURL?.path ?? ""
                }
                .disabled(vaultManager.vaultURL == nil)
                .help("Использовать открытый vault как репозиторий проекта")
                Button("Сбросить") { settingsStore.settings.projectRepoPath = "" }
                    .disabled(settingsStore.settings.projectRepoPath.isEmpty)
                    .help("Отключить инструменты проекта")
            }
            if let warning = projectRepoWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Label(settingsStore.settings.projectRepoPath.isEmpty
                  ? "Репозиторий не выбран — инструменты недоступны"
                  : "Репозиторий выбран — инструменты готовы (включаются per-чат в меню «Инструменты» или чипами)",
                  systemImage: settingsStore.settings.projectRepoPath.isEmpty
                  ? "circle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(settingsStore.settings.projectRepoPath.isEmpty
                                 ? Color.secondary : .green)
            docsIndexRow
            // Каталог: что именно умеет ассистент (только чтение).
            ForEach(Self.builtinCatalog, id: \.name) { definition in
                VStack(alignment: .leading, spacing: 1) {
                    Text(definition.name)
                        .font(.callout.monospaced())
                    Text(definition.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func refreshProjectRepoWarning() async {
        let path = settingsStore.settings.projectRepoPath
        guard !path.isEmpty else {
            projectRepoWarning = nil
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            projectRepoWarning = "Папка не найдена — инструменты проекта работать не будут."
            return
        }
        let isRepo = await GitClient(repoURL: URL(fileURLWithPath: path)).isRepository()
        projectRepoWarning = isRepo ? nil
            : "Папка не является корнем git-репозитория: git-инструменты будут недоступны, останутся list_files и read_file."
    }
}

// MARK: - GitHub-токен (задача 36)

/// Секция токена GitHub для PR-watch пайплайнов. Паттерн providerRow:
/// SecureField + Сохранить/Удалить, значение никогда не показывается,
/// хранение — Keychain (запись «github-token»). Для отслеживания PR хватает
/// read-only доступа; без токена GitHub даёт всего 60 запросов в час.
struct GitHubTokenSection: View {
    @State private var draft = ""
    /// Тик перерисовки статуса «токен задан» (KeyStore — не ObservableObject).
    @State private var keyChangeTick = 0

    var body: some View {
        Section("GitHub (PR-watch пайплайнов)") {
            let hasKey = keyChangeTick >= 0 && KeyStore.hasKey(for: PRWatcher.githubTokenID)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Personal access token")
                        .fontWeight(.medium)
                    Spacer()
                    Label(hasKey ? "токен задан" : "токена нет",
                          systemImage: hasKey ? "checkmark.circle" : "circle")
                        .font(.caption)
                        .foregroundStyle(hasKey ? .green : .secondary)
                }
                HStack {
                    SecureField("Новый токен", text: $draft)
                        .textFieldStyle(.roundedBorder)
                    Button("Сохранить") {
                        KeyStore.setKey(draft, for: PRWatcher.githubTokenID)
                        draft = ""
                        keyChangeTick += 1
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey {
                        Button("Удалить", role: .destructive) {
                            KeyStore.setKey("", for: PRWatcher.githubTokenID)
                            keyChangeTick += 1
                        }
                    }
                }
                HStack(spacing: 4) {
                    Link("Как выпустить токен",
                         destination: URL(string: "https://github.com/settings/tokens")!)
                    Text("— достаточно read-only (Public repos / repo:read). Без токена лимит GitHub — 60 запросов в час.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Базы знаний (задача 34)

/// Секция реестра баз знаний: глобальные тумблеры встроенных баз (vault,
/// проект) и управление папочными базами — добавить/переименовать не даём
/// (имя = имя папки), статистика индекса, сброс, удаление. Per-чат выбор —
/// чип «База» в чате; здесь настраивается, что вообще доступно.
struct KnowledgeBasesSection: View {
    @ObservedObject var store: KnowledgeBaseStore
    /// Индексы папочных баз: статистика и сброс.
    let folderService: FolderIndexService

    /// Статистика индексов папочных баз по id; nil в значении — не строился.
    @State private var folderStats: [String: FolderIndexService.Stats] = [:]

    var body: some View {
        Section("Базы знаний (RAG)") {
            ForEach(store.bases) { base in
                baseRow(base)
            }
            Button("Добавить папку…") { pickFolder() }
                .help("Добавить папку с .md-заметками как отдельную базу знаний (индексируется при первом вопросе)")
            Text("Включённые базы доступны в чатах: чип «База» выбирает, где ищет конкретный чат; модель с function calling ищет сама через rag_search.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: store.bases.filter { $0.kind == .folder }.map(\.id)) {
            await refreshStats()
        }
    }

    @ViewBuilder
    private func baseRow(_ base: KnowledgeBase) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { base.enabled },
                set: { store.setEnabled(id: base.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(base.enabled ? "Выключить базу во всех чатах" : "Включить базу")
            VStack(alignment: .leading, spacing: 1) {
                Text(base.name)
                Text(baseDetail(base))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if base.kind == .folder {
                Button("Сбросить индекс") {
                    Task {
                        await folderService.reset(root: URL(fileURLWithPath: base.path))
                        await refreshStats()
                    }
                }
                .controlSize(.small)
                .help("Индекс перестроится при следующем вопросе")
                Button(role: .destructive) {
                    store.removeBase(id: base.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Удалить базу из реестра (файлы папки не трогаются)")
            }
        }
    }

    /// Подпись базы: у встроенных — откуда путь, у папок — путь + статистика.
    private func baseDetail(_ base: KnowledgeBase) -> String {
        switch base.kind {
        case .vault:
            return "Заметки открытого vault (индекс — в «Общих»)"
        case .project:
            return "README и docs/ репозитория проекта (выбирается выше)"
        case .folder:
            guard let stats = folderStats[base.id] else {
                return "\(base.path) · индекс построится при первом вопросе"
            }
            return "\(base.path) · \(stats.files) файлов · \(stats.chunks) чанков"
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Добавить"
        panel.message = "Выберите папку с .md-заметками для базы знаний"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addFolder(url: url)
    }

    private func refreshStats() async {
        var stats: [String: FolderIndexService.Stats] = [:]
        for base in store.bases where base.kind == .folder {
            if let s = await folderService.stats(root: URL(fileURLWithPath: base.path)) {
                stats[base.id] = s
            }
        }
        folderStats = stats
    }
}

// MARK: - Синхронизация

struct SyncSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var syncViewModel: SyncViewModel

    var body: some View {
        Form {
            Section("Авто-бэкап") {
                Picker("Интервал", selection: $store.settings.autoBackupMinutes) {
                    ForEach(SyncViewModel.autoBackupChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "выключен" : "каждые \(minutes) мин")
                            .tag(minutes)
                    }
                }
                Text("Если в vault есть изменения — commit «vault backup: <дата>» и push. Ошибка пуша не теряет коммит: следующий прогон допушит.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Состояние") {
                switch syncViewModel.repoState {
                case .noVault:
                    Text("Vault не открыт.").foregroundStyle(.secondary)
                case .checking:
                    ProgressView().controlSize(.small)
                case .gitUnavailable(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                case .notARepo:
                    Text("Синхронизация не включена — включите в панели синка (иконка в тулбаре главного окна).")
                        .foregroundStyle(.secondary)
                case .ready:
                    if let status = syncViewModel.status {
                        LabeledContent("Ветка", value: status.branch ?? "—")
                        if let upstream = status.upstream {
                            LabeledContent("Upstream", value: upstream)
                        }
                        LabeledContent("Изменений", value: "\(status.changes.count)")
                        if status.ahead > 0 || status.behind > 0 {
                            LabeledContent("Расхождение", value: "↑\(status.ahead) ↓\(status.behind)")
                        }
                    }
                    ForEach(syncViewModel.remotes, id: \.name) { remote in
                        LabeledContent(remote.name) {
                            Text(GitRemoteURL.strippingCredential(remote.url))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await syncViewModel.refresh() }
    }
}
