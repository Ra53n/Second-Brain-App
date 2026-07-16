// AppModel.swift — объектный граф приложения (задача 17).
//
// До задачи 17 весь граф создавался в ContentView.init; окно Settings (Cmd+,)
// живёт в ОТДЕЛЬНОЙ сцене и должно видеть те же объекты — поэтому владелец
// перенесён сюда, а сцены (WindowGroup и Settings) получают один @StateObject
// AppModel из SecondBrainApp. Здесь же — связки между сторами и владельцами
// значений (настройка ↔ поведение): dot-папки, авто-бэкап, idle-таймаут,
// привязка git-синка к открытому vault.

import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let settingsStore: SettingsStore
    let vaultManager: VaultManager
    let searchViewModel: SearchViewModel
    let providerRegistry: ProviderRegistry
    let functionRouter: FunctionRouter
    let ollamaManager: OllamaManager
    let localModelsViewModel: LocalModelsViewModel
    let whisperProvider: WhisperKitProvider
    let whisperModelsViewModel: WhisperModelsViewModel
    let meetingsViewModel: MeetingsViewModel
    let chatViewModel: ChatViewModel
    let ragIndexManager: RagIndexManager
    let mcpServersViewModel: MCPServersViewModel
    let syncViewModel: SyncViewModel
    /// Инструменты проекта для чата (задача 21): исполнитель по projectRepoPath.
    let projectToolsProvider: ProjectToolsProvider

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // Настройки — первыми: от них зависит поведение при создании графа.
        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore

        let manager = VaultManager(restoreLast: settingsStore.settings.restoreLastVault)
        manager.showsDotItems = settingsStore.settings.showsDotItems
        vaultManager = manager
        searchViewModel = SearchViewModel(vaultManager: manager)

        let registry = ProviderRegistry()
        CloudProviders.registerAll(in: registry)
        let ollama = OllamaManager()
        LocalProviders.register(in: registry, ollamaManager: ollama)
        ollamaManager = ollama
        localModelsViewModel = LocalModelsViewModel(manager: ollama)
        let whisper = WhisperKitProvider()
        LocalProviders.registerWhisper(in: registry, provider: whisper)
        whisperProvider = whisper
        whisperModelsViewModel = WhisperModelsViewModel(provider: whisper)
        providerRegistry = registry
        let router = FunctionRouter(registry: registry)
        functionRouter = router
        meetingsViewModel = MeetingsViewModel(vaultManager: manager, functionRouter: router)
        chatViewModel = ChatViewModel(router: router, registry: registry)
        ragIndexManager = RagIndexManager(vaultManager: manager, router: router)
        mcpServersViewModel = MCPServersViewModel()
        syncViewModel = SyncViewModel()
        projectToolsProvider = ProjectToolsProvider(settingsStore: settingsStore)

        wire()
    }

    /// Связки «настройка ↔ поведение». Все подписки с removeDuplicates/
    /// проверкой равенства — двусторонние связки не зацикливаются.
    private func wire() {
        // Тумблер dot-папок живёт и в тулбаре дерева, и в настройках —
        // переключение в любом месте персистится.
        vaultManager.$showsDotItems
            .dropFirst()
            .sink { [weak self] shows in self?.settingsStore.settings.showsDotItems = shows }
            .store(in: &cancellables)
        settingsStore.$settings
            .map(\.showsDotItems)
            .removeDuplicates()
            .sink { [weak self] shows in
                guard let self, self.vaultManager.showsDotItems != shows else { return }
                self.vaultManager.showsDotItems = shows
            }
            .store(in: &cancellables)

        // Интервал авто-бэкапа: стор — источник истины, панель синка — второй UI.
        syncViewModel.autoBackupMinutes = settingsStore.settings.autoBackupMinutes
        syncViewModel.$autoBackupMinutes
            .dropFirst()
            .sink { [weak self] minutes in self?.settingsStore.settings.autoBackupMinutes = minutes }
            .store(in: &cancellables)
        settingsStore.$settings
            .map(\.autoBackupMinutes)
            .removeDuplicates()
            .sink { [weak self] minutes in
                guard let self, self.syncViewModel.autoBackupMinutes != minutes else { return }
                self.syncViewModel.autoBackupMinutes = minutes
            }
            .store(in: &cancellables)

        // Idle-таймаут локальных рантаймов: применяем сразу и на изменение.
        settingsStore.$settings
            .map(\.localIdleMinutes)
            .removeDuplicates()
            .sink { [weak self] minutes in
                let seconds = TimeInterval(max(1, minutes) * 60)
                self?.ollamaManager.setIdleTimeout(seconds)
                self?.whisperProvider.setIdleTimeout(seconds)
            }
            .store(in: &cancellables)

        // Git-синк привязан к открытому vault (стартовому и при смене).
        vaultManager.$vaultURL
            .removeDuplicates()
            .sink { [weak self] url in self?.syncViewModel.attach(vaultURL: url) }
            .store(in: &cancellables)
    }
}
