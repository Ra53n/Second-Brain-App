// ContentView.swift — корневой экран: NavigationSplitView (разделы → контент → detail).
//
// Живые разделы: «Заметки» (задачи 02–05) и «Встречи» (запись — задача 06;
// транскрипция и заметки встреч придут в 11). Остальные — заглушки до своих
// задач (Чат — 12, Настройки — 17).

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

    /// Номер задачи из tasks/, в которой раздел получит содержимое.
    var plannedTask: String {
        switch self {
        case .notes: return "02–05"
        case .meetings: return "11" // запись уже есть (06), пайплайн встречи — в 11
        case .chat: return "12–14"
        case .settings: return "17"
        }
    }
}

/// Корневой view: сайдбар разделов, контент раздела, detail.
/// VaultManager создаётся здесь — один на приложение, переживает смену разделов.
struct ContentView: View {
    @State private var selection: AppSection? = .notes
    @StateObject private var vaultManager: VaultManager
    @StateObject private var searchViewModel: SearchViewModel
    /// Реестр LLM-провайдеров + роутер функций (задачи 07/08). Ещё не используются
    /// UI (чат — 12, встречи — 11, настройки — 17) — создаются здесь заранее,
    /// чтобы объектный граф был готов, когда эти разделы появятся.
    @StateObject private var providerRegistry: ProviderRegistry
    @StateObject private var functionRouter: FunctionRouter
    /// Раздел «Встречи»: запись и список записей (задача 06).
    @StateObject private var meetingsViewModel: MeetingsViewModel
    /// Локальный рантайм Ollama + экран управления моделями (задача 09).
    @StateObject private var ollamaManager: OllamaManager
    @StateObject private var localModelsViewModel: LocalModelsViewModel
    /// Локальная транскрипция WhisperKit (задача 10).
    @StateObject private var whisperProvider: WhisperKitProvider
    @StateObject private var whisperModelsViewModel: WhisperModelsViewModel
    /// Раздел «Чат» (задача 12).
    @StateObject private var chatViewModel: ChatViewModel
    /// RAG-индекс vault (задача 13).
    @StateObject private var ragIndexManager: RagIndexManager
    @State private var showsQuickSwitcher = false

    init() {
        // SearchViewModel подписан на VaultManager — создаём парой.
        let manager = VaultManager()
        _vaultManager = StateObject(wrappedValue: manager)
        _searchViewModel = StateObject(wrappedValue: SearchViewModel(vaultManager: manager))

        let registry = ProviderRegistry()
        CloudProviders.registerAll(in: registry)
        let ollama = OllamaManager()
        LocalProviders.register(in: registry, ollamaManager: ollama)
        _ollamaManager = StateObject(wrappedValue: ollama)
        _localModelsViewModel = StateObject(wrappedValue: LocalModelsViewModel(manager: ollama))
        let whisper = WhisperKitProvider()
        LocalProviders.registerWhisper(in: registry, provider: whisper)
        _whisperProvider = StateObject(wrappedValue: whisper)
        _whisperModelsViewModel = StateObject(wrappedValue: WhisperModelsViewModel(provider: whisper))
        _providerRegistry = StateObject(wrappedValue: registry)
        let router = FunctionRouter(registry: registry)
        _functionRouter = StateObject(wrappedValue: router)
        // Встречи зависят от vault (записи) и роутера (транскрипция/summary).
        _meetingsViewModel = StateObject(wrappedValue: MeetingsViewModel(vaultManager: manager,
                                                                         functionRouter: router))
        _chatViewModel = StateObject(wrappedValue: ChatViewModel(router: router,
                                                                 registry: registry))
        _ragIndexManager = StateObject(wrappedValue: RagIndexManager(vaultManager: manager,
                                                                     router: router))
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
    /// список записей, остальные — заглушки.
    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .notes:
            VaultPane(manager: vaultManager, searchViewModel: searchViewModel)
        case .meetings:
            MeetingsPane(viewModel: meetingsViewModel)
        case .chat:
            ChatListPane(viewModel: chatViewModel)
        case .settings:
            // Пока единственная секция настроек — локальные модели (задачи 09/10);
            // остальные настройки добавит задача 17.
            LocalModelsPane(viewModel: localModelsViewModel,
                            manager: ollamaManager,
                            whisperViewModel: whisperModelsViewModel,
                            ragManager: ragIndexManager)
        case .some(let section):
            ContentUnavailableView {
                Label(section.rawValue, systemImage: section.systemImage)
            } description: {
                Text("Раздел появится в задаче \(section.plannedTask).")
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
        guard chatViewModel.ragProvider == nil else { return }
        chatViewModel.ragProvider = { [weak ragIndexManager, weak functionRouter] chat, query in
            guard let manager = ragIndexManager else { return nil }
            let needsLLM = chat.configuration.ragQueryRewrite || chat.configuration.ragRerankEnabled
            let chatProvider = needsLLM ? functionRouter?.resolveChatProvider(for: .chat) : nil
            return await manager.retrieveForChat(query: query,
                                                 history: chat.messages,
                                                 configuration: chat.configuration,
                                                 chatProvider: chatProvider)
        }
    }

    /// Расширения файлов, которые открываются в markdown-редакторе.
    private static let editableExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Detail: «Заметки» — редактор или информация о файле, «Чат» — диалог.
    @ViewBuilder
    private var sectionDetail: some View {
        if selection == .chat {
            ChatDetailView(viewModel: chatViewModel,
                           resolveWikilink: { vaultManager.linkIndex?.resolve($0) })
                .onAppear { wireRagProvider() }
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
                description: Text("Содержимое раздела появится в своей задаче.")
            )
        }
    }
}
