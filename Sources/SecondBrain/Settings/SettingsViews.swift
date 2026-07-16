// SettingsViews.swift — окно Settings (Cmd+,) со вкладками (задача 17).
//
// Вкладки: Общие (vault + RAG-индекс), Провайдеры (ключи), Модели (роутинг
// функция → провайдер+модель), Встречи (промпт раскладки, папка/источник по
// умолчанию), Локальные модели (Ollama/Whisper/idle), MCP, Синхронизация.
// Всё «настраиваемое» сведено сюда, ничего не потеряно: локальные модели и
// MCP переехали из бывшего раздела сайдбара, синк дублирует панель тулбара.
//
// View только читают сторы/вью-модели из AppModel; логика — в них.

import AppKit
import SwiftUI

/// Корень окна настроек: TabView со стандартными тулбар-вкладками macOS.
struct SettingsRootView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsTab(store: model.settingsStore,
                               vaultManager: model.vaultManager,
                               ragManager: model.ragIndexManager)
                .tabItem { Label("Общие", systemImage: "gearshape") }
            ProvidersSettingsTab(registry: model.providerRegistry)
                .tabItem { Label("Провайдеры", systemImage: "key") }
            ModelsSettingsTab(router: model.functionRouter,
                              registry: model.providerRegistry)
                .tabItem { Label("Модели", systemImage: "cpu") }
            MeetingsSettingsTab(meetingsViewModel: model.meetingsViewModel)
                .tabItem { Label("Встречи", systemImage: "mic") }
            LocalModelsPane(viewModel: model.localModelsViewModel,
                            manager: model.ollamaManager,
                            whisperViewModel: model.whisperModelsViewModel,
                            settingsStore: model.settingsStore)
                .tabItem { Label("Локальные модели", systemImage: "desktopcomputer") }
            MCPSettingsTab(viewModel: model.mcpServersViewModel,
                           settingsStore: model.settingsStore)
                .tabItem { Label("MCP", systemImage: "wrench.and.screwdriver") }
            SyncSettingsTab(store: model.settingsStore, syncViewModel: model.syncViewModel)
                .tabItem { Label("Синхронизация", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

// MARK: - Общие

struct GeneralSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var ragManager: RagIndexManager

    /// Предупреждение «выбранная папка — не git-репозиторий» (не блокирует:
    /// list_files/read_file работают и без git).
    @State private var projectRepoWarning: String?

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
            projectToolsSection
        }
        .formStyle(.grouped)
        // Проверка «папка — git-репозиторий?» при каждом изменении пути.
        .task(id: store.settings.projectRepoPath) { await refreshProjectRepoWarning() }
    }

    /// Репозиторий для встроенных инструментов проекта в чате (задача 21).
    private var projectToolsSection: some View {
        Section("Инструменты проекта (чат)") {
            HStack {
                Text("Репозиторий")
                Spacer()
                Text(store.settings.projectRepoPath.isEmpty
                     ? "не выбран" : store.settings.projectRepoPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Выбрать…") { pickProjectRepo() }
                    .help("Выбрать папку git-репозитория, по которому ассистент сможет ходить")
                Button("Текущий vault") {
                    store.settings.projectRepoPath = vaultManager.vaultURL?.path ?? ""
                }
                .disabled(vaultManager.vaultURL == nil)
                .help("Использовать открытый vault как репозиторий проекта")
                Button("Сбросить") { store.settings.projectRepoPath = "" }
                    .disabled(store.settings.projectRepoPath.isEmpty)
                    .help("Отключить инструменты проекта")
            }
            if let warning = projectRepoWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Ассистент в чате сможет смотреть ветки, статус, историю и файлы этой папки (только чтение). Включается per-чат в меню «Инструменты».")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pickProjectRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.message = "Выберите корень git-репозитория проекта"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.projectRepoPath = url.path
    }

    private func refreshProjectRepoWarning() async {
        let path = store.settings.projectRepoPath
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
                let model = registry.descriptor(for: newID)?.defaultModel ?? ""
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
        }
        .formStyle(.grouped)
        .onAppear {
            let settings = MeetingSettingsStore.load()
            defaultFolder = settings.defaultFolder
            defaultSource = settings.defaultSource ?? .microphone
        }
    }
}

// MARK: - MCP

struct MCPSettingsTab: View {
    @ObservedObject var viewModel: MCPServersViewModel
    /// Стор нужен для предзаполнения git-шаблона путём репозитория (задача 21).
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            MCPServersSection(viewModel: viewModel,
                              projectRepoPath: settingsStore.settings.projectRepoPath)
        }
        .formStyle(.grouped)
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
