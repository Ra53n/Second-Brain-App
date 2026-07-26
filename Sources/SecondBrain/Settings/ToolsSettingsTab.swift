// ToolsSettingsTab.swift — вкладка «Инструменты»: репозиторий проекта + встроенные
// инструменты + MCP-серверы + базы знаний + токен GitHub (часть SettingsViews, задача 77).

import AppKit
import SwiftUI

/// Вкладка «Инструменты» (задача 27): единая точка настройки туллинга —
/// репозиторий проекта (переехал из «Общих») + каталог встроенных
/// инструментов + MCP-серверы (бывшая вкладка MCP).
struct ToolsSettingsTab: View {
    @ObservedObject var viewModel: MCPServersViewModel
    @ObservedObject var settingsStore: SettingsStore
    /// Для кнопки «Текущий vault».
    @ObservedObject var vaultManager: VaultManager
    /// Статус RAG-индекса документации проекта (задачи 28, 47).
    let projectToolsProvider: ProjectToolsProvider
    /// Реестр баз знаний (задача 34): секция управления папочными базами.
    @ObservedObject var knowledgeBaseStore: KnowledgeBaseStore
    let knowledgeBaseManager: KnowledgeBaseManager

    @Environment(\.openSettings) private var openSettings

    /// Предупреждение «выбранная папка — не git-репозиторий» (не блокирует:
    /// list_files/read_file работают и без git).
    @State private var projectRepoWarning: String?

    /// Каталог встроенных инструментов статичен — считается один раз.
    private static let builtinCatalog = ToolRegistry.projectToolCatalog()

    var body: some View {
        Form {
            builtinToolsSection
            ProjectDocsStatusSection(provider: projectToolsProvider,
                                     repoPath: settingsStore.settings.projectRepoPath,
                                     onOpenSettingsTab: { tab in
                SettingsTabRouter.open(tab, openSettings: { openSettings() })
            })
            KnowledgeBasesSection(store: knowledgeBaseStore,
                                  folderService: knowledgeBaseManager.folderService)
            MCPServersSection(viewModel: viewModel,
                              projectRepoPath: settingsStore.settings.projectRepoPath)
            GitHubTokenSection()
        }
        .formStyle(.grouped)
        // Проверка «папка — git-репозиторий?» при каждом изменении пути.
        .task(id: settingsStore.settings.projectRepoPath) {
            await refreshProjectRepoWarning()
        }
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
