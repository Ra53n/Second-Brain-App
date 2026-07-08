// ContentView.swift — корневой экран: NavigationSplitView (разделы → контент → detail).
//
// Раздел «Заметки» жив (задача 02): средняя колонка — дерево vault, detail —
// информация о выбранном файле (редактор придёт в задаче 03). Остальные разделы —
// заглушки до своих задач (Встречи — 11, Чат — 12, Настройки — 17).

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
        case .meetings: return "06, 11"
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
    @State private var showsQuickSwitcher = false

    init() {
        // SearchViewModel подписан на VaultManager — создаём парой.
        let manager = VaultManager()
        _vaultManager = StateObject(wrappedValue: manager)
        _searchViewModel = StateObject(wrappedValue: SearchViewModel(vaultManager: manager))

        let registry = ProviderRegistry()
        CloudProviders.registerAll(in: registry)
        _providerRegistry = StateObject(wrappedValue: registry)
        _functionRouter = StateObject(wrappedValue: FunctionRouter(registry: registry))
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

    /// Средняя колонка: для «Заметок» — дерево vault, для остальных — заглушка.
    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .notes:
            VaultPane(manager: vaultManager, searchViewModel: searchViewModel)
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

    /// Расширения файлов, которые открываются в markdown-редакторе.
    private static let editableExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Detail: для «Заметок» — редактор (markdown/текст) или информация о файле.
    @ViewBuilder
    private var sectionDetail: some View {
        if selection == .notes {
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
