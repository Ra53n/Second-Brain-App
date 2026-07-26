// SettingsViews.swift — окно Settings (Cmd+,): корень с TabView + роутер вкладок (задача 17).
//
// Сами вкладки — в соседних файлах по одной на вкладку (GeneralSettingsTab.swift,
// ProvidersSettingsTab.swift, ModelsSettingsTab.swift, MeetingsSettingsTab.swift,
// ToolsSettingsTab.swift, LocalRuntime/LocalModelsPane.swift; задача 77). Здесь
// остаётся общее: enum вкладок, роутер открытия, TabView-корень, SyncSettingsTab
// (единственный потребитель) и ProjectRepoPicker (используется вкладкой «Инструменты»
// и мастером в пустом чате — задача 27).
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
