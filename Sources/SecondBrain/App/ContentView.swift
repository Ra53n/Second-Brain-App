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
    case settings = "Настройки"

    var id: String { rawValue }

    /// SF-символ раздела для сайдбара.
    var systemImage: String {
        switch self {
        case .notes: return "doc.text"
        case .meetings: return "mic"
        case .chat: return "bubble.left.and.bubble.right"
        case .settings: return "gearshape"
        }
    }
}

/// Корневой view: сайдбар разделов, контент раздела, detail.
struct ContentView: View {
    @State private var selection: AppSection? = .notes
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
        // Quick switcher: команда меню (Cmd+P, App.swift) шлёт нотификацию.
        .onReceive(NotificationCenter.default.publisher(for: .showQuickSwitcher)) { _ in
            showsQuickSwitcher = true
        }
        // «Открыть заметку» из раздела встреч: переключаемся на «Заметки».
        .onReceive(NotificationCenter.default.publisher(for: .openNoteInEditor)) { notification in
            guard let url = notification.object as? URL else { return }
            selection = .notes
            vaultManager.rebuild() // свежесозданная заметка могла ещё не попасть в дерево
            vaultManager.selection = url
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
            MeetingsPane(viewModel: model.meetingsViewModel)
        case .chat:
            ChatListPane(viewModel: model.chatViewModel)
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

    /// Связка чата с RAG (задача 14): ретрив идёт через менеджер индекса;
    /// rewrite/rerank используют тот же чат-роутер. Однократно, лениво.
    private func wireRagProvider() {
        let chatViewModel = model.chatViewModel
        guard chatViewModel.ragProvider == nil else { return }
        chatViewModel.ragProvider = { [weak ragIndexManager = model.ragIndexManager,
                                       weak functionRouter = model.functionRouter] chat, query in
            guard let manager = ragIndexManager else { return nil }
            let needsLLM = chat.configuration.ragQueryRewrite || chat.configuration.ragRerankEnabled
            // Задача 28: у реранка/переписывания своя функция роутинга.
            let chatProvider = needsLLM ? functionRouter?.resolveChatProvider(for: .ragRerank) : nil
            return await manager.retrieveForChat(query: query,
                                                 history: chat.messages,
                                                 configuration: chat.configuration,
                                                 chatProvider: chatProvider)
        }
    }

    /// Связка чата с MCP (задача 15): инструменты включённых серверов и
    /// исполнитель вызовов. Однократно, лениво.
    private func wireMCPBridge() {
        let chatViewModel = model.chatViewModel
        guard chatViewModel.mcpBridge == nil else { return }
        let manager = model.mcpServersViewModel.manager
        chatViewModel.mcpBridge = ChatViewModel.MCPBridge(
            tools: { [weak mcpServersViewModel = model.mcpServersViewModel] serverIDs in
                await mcpServersViewModel?.tools(for: serverIDs) ?? []
            },
            execute: { name, args in
                await manager.call(qualifiedName: name, argumentsJSON: args)
            })
    }

    /// Связка чата со встроенными инструментами проекта (задача 21):
    /// провайдер держит исполнитель для текущего projectRepoPath и
    /// пересоздаёт его при смене пути. Однократно, лениво.
    private func wireProjectTools() {
        let chatViewModel = model.chatViewModel
        guard chatViewModel.projectToolsBridge == nil else { return }
        let provider = model.projectToolsProvider
        chatViewModel.projectToolsBridge = ChatViewModel.ProjectToolsBridge(
            available: { provider.current() != nil },
            tools: { provider.current()?.registry.definitions() ?? [] },
            execute: { name, args in
                guard let current = provider.current() else {
                    return "ERROR: репозиторий проекта не выбран (Настройки → Инструменты)"
                }
                return await current.executor.execute(name: name, argumentsJSON: args)
            })
        // /help (задачи 22, 25): RAG-ретрив по докам репозитория с фолбэком
        // на полный контекст — вся логика в ProjectToolsProvider.
        chatViewModel.projectDocsProvider = { question in
            await provider.helpContext(question: question)
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
                           resolveWikilink: { vaultManager.linkIndex?.resolve($0) })
                .onAppear {
                    wireRagProvider()
                    wireMCPBridge()
                    wireProjectTools()
                }
        } else if selection == .notes {
            if let url = vaultManager.selection,
               let node = vaultManager.root?.find(url) {
                if !node.isDirectory,
                   Self.editableExtensions.contains(url.pathExtension.lowercased()) {
                    EditorPane(url: url, vaultManager: vaultManager)
                } else {
                    FileInfoView(node: node)
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
