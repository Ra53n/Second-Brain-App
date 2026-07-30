// ContentView.swift — корневой экран: NavigationSplitView (разделы → контент → detail).
//
// Живые разделы: «Заметки» (02–05), «Встречи» (06/11), «Чат» (12–15).
// «Настройки» с задачи 17 живут в стандартном окне Settings (Cmd+,) —
// раздел сайдбара лишь открывает его. Объектный граф приложения создаёт
// AppModel (общий для главного окна и окна Settings), View только читают.

import SwiftUI

/// Разделы приложения в сайдбаре. Порядок фиксирован — как в VISION.md.
enum AppSection: String, CaseIterable, Identifiable {
    case notes = "Заметки"
    case meetings = "Встречи"
    case chat = "Чат"
    case pipelines = "Пайплайны"
    case finetune = "Тюнинг"
    case settings = "Настройки"

    var id: String { rawValue }

    /// SF-символ раздела для сайдбара.
    var systemImage: String {
        switch self {
        case .notes: return "doc.text"
        case .meetings: return "mic"
        case .chat: return "bubble.left.and.bubble.right"
        case .pipelines: return "gearshape.arrow.triangle.2.circlepath"
        case .finetune: return "slider.horizontal.3"
        case .settings: return "gearshape"
        }
    }
}

/// Корневой view: сайдбар разделов, контент раздела, detail.
struct ContentView: View {
    @State private var selection: AppSection? = .notes
    /// Открытие окна настроек по ссылке secondbrain://settings/<вкладка> (задача 50).
    @Environment(\.openSettings) private var openSettings
    /// Общий объектный граф (владелец — SecondBrainApp).
    let model: AppModel
    /// Наблюдаемые здесь объекты: body читает их состояние напрямую
    /// (дерево/выбор vault — detail, ошибки поиска — alert).
    @ObservedObject private var vaultManager: VaultManager
    @ObservedObject private var searchViewModel: SearchViewModel
    /// Панель синка показывается отсюда (стабильный якорь окна, задача 24).
    @ObservedObject private var syncViewModel: SyncViewModel
    @State private var showsQuickSwitcher = false

    init(model: AppModel) {
        self.model = model
        _vaultManager = ObservedObject(wrappedValue: model.vaultManager)
        _searchViewModel = ObservedObject(wrappedValue: model.searchViewModel)
        _syncViewModel = ObservedObject(wrappedValue: model.syncViewModel)
    }

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .frame(minWidth: 180)
        } content: {
            sectionContent
                .frame(minWidth: 240)
        } detail: {
            sectionDetail
                .frame(minWidth: 420, minHeight: 600)
        }
        // Индикатор git-синхронизации vault (задача 16) — глобальный тулбар.
        .toolbar {
            ToolbarItem {
                SyncStatusButton(viewModel: model.syncViewModel)
            }
        }
        // Панель синка прикреплена к корню окна, а НЕ к кнопке тулбара:
        // ToolbarItem пересоздаётся при обновлении статуса (refresh при
        // открытии), и поповер с якорем-кнопкой закрывался сразу (задача 24).
        .popover(isPresented: $syncViewModel.showsPanel,
                 attachmentAnchor: .point(.topTrailing),
                 arrowEdge: .bottom) {
            GitSyncPanel(viewModel: syncViewModel)
        }
        // Навигация по ссылке secondbrain:// (задача 50) — единственная точка
        // входа deep link'ов. Только навигация: URL может открыть кто угодно.
        .onOpenURL { url in
            switch DeepLinkParser.parse(url) {
            case .section(let section):
                selection = section
            case .settings(let tab):
                SettingsTabRouter.open(tab, openSettings: openSettings.callAsFunction)
            case nil:
                break   // мусорная ссылка — молчим, экран не трогаем
            }
        }
        // Quick switcher: команда меню (Cmd+P, App.swift) шлёт нотификацию.
        .onReceive(NotificationCenter.default.publisher(for: .showQuickSwitcher)) { _ in
            showsQuickSwitcher = true
        }
        // «Открыть заметку» из раздела встреч: переключаемся на «Заметки».
        .onReceive(NotificationCenter.default.publisher(for: .openNoteInEditor)) { notification in
            guard let url = notification.object as? URL else { return }
            selection = .notes
            vaultManager.rebuild() // свежесозданная заметка могла ещё не попасть в дерево
            vaultManager.open(url)
        }
        // «Открыть чат» из истории прогонов пайплайна (задача 36).
        .onReceive(NotificationCenter.default.publisher(for: .openPipelineChat)) { notification in
            guard let chatID = notification.object as? UUID else { return }
            selection = .chat
            model.chatViewModel.selectedChatID = chatID
        }
        .sheet(isPresented: $showsQuickSwitcher) {
            QuickSwitcherView(vaultManager: vaultManager)
        }
        .alert(
            "Поиск",
            isPresented: Binding(
                get: { searchViewModel.lastError != nil },
                set: { if !$0 { searchViewModel.lastError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(searchViewModel.lastError ?? "") }
        )
    }

    /// Средняя колонка: «Заметки» — дерево vault, «Встречи» — запись и
    /// список записей, «Настройки» — переход к окну Settings.
    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .notes:
            VaultPane(manager: vaultManager, searchViewModel: searchViewModel)
        case .meetings:
            // Панели записи нужна ширина (кнопка + источник + название в одну
            // строку, строки списка с действиями) — дефолтная колонка ~250 pt
            // превращала её в вертикальную кашу (задача 41).
            MeetingsPane(viewModel: model.meetingsViewModel)
                .navigationSplitViewColumnWidth(min: 360, ideal: 480, max: 720)
        case .chat:
            ChatListPane(viewModel: model.chatViewModel)
        case .pipelines:
            PipelinesPane(store: model.pipelineStore,
                          engine: model.pipelineEngine,
                          watcher: model.prWatcher)
        case .finetune:
            // Средней колонке нужна ширина под счётчики строк и статус прогона
            // (дефолт превращает список в вертикальную кашу, как в задаче 41).
            FineTunePane(store: model.fineTuneStore, viewModel: model.fineTuneViewModel)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 560)
        case .settings:
            // Настройки живут в стандартном окне Settings (задача 17).
            ContentUnavailableView {
                Label("Настройки", systemImage: "gearshape")
            } description: {
                Text("Все настройки — в отдельном окне (⌘,).")
            } actions: {
                SettingsLink {
                    Text("Открыть настройки")
                }
            }
        case nil:
            ContentUnavailableView(
                "Выберите раздел",
                systemImage: "sidebar.left",
                description: Text("Разделы — в сайдбаре слева.")
            )
        }
    }

    /// Расширения файлов, которые открываются в markdown-редакторе.
    private static let editableExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Detail: «Заметки» — редактор или информация о файле, «Чат» — диалог.
    @ViewBuilder
    private var sectionDetail: some View {
        if selection == .chat {
            ChatDetailView(viewModel: model.chatViewModel,
                           settingsStore: model.settingsStore,
                           mcpViewModel: model.mcpServersViewModel,
                           ragIndexManager: model.ragIndexManager,
                           projectToolsProvider: model.projectToolsProvider,
                           knowledgeBaseStore: model.knowledgeBaseStore,
                           knowledgeBaseManager: model.knowledgeBaseManager,
                           resolveWikilink: { vaultManager.linkIndex?.resolve($0) })
        } else if selection == .pipelines {
            PipelineDetailView(store: model.pipelineStore,
                               engine: model.pipelineEngine,
                               watcher: model.prWatcher,
                               chatViewModel: model.chatViewModel,
                               mcpViewModel: model.mcpServersViewModel,
                               knowledgeBaseStore: model.knowledgeBaseStore)
        } else if selection == .finetune {
            FineTuneDetailView(store: model.fineTuneStore, viewModel: model.fineTuneViewModel)
        } else if selection == .notes {
            if let url = vaultManager.selection,
               let node = vaultManager.root?.find(url) {
                // Breadcrumb сверху (задача 42) — общий для редактора, папки
                // и инфо-панели: пользователь всегда видит, где лежит узел.
                VStack(spacing: 0) {
                    NoteBreadcrumbBar(node: node, manager: vaultManager)
                    Divider()
                    if node.isDirectory {
                        FolderContentsView(node: node, manager: vaultManager)
                    } else if Self.editableExtensions.contains(url.pathExtension.lowercased()) {
                        EditorPane(url: url, vaultManager: vaultManager)
                    } else {
                        FileInfoView(node: node)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Ничего не выбрано",
                    systemImage: "doc.text",
                    description: Text("Выберите файл в дереве слева.")
                )
            }
        } else {
            ContentUnavailableView(
                "Пусто",
                systemImage: "square.dashed",
                description: Text("Содержимое раздела — в средней колонке.")
            )
        }
    }
}
