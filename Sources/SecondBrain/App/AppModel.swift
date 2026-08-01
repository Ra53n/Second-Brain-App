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
    /// Реестр баз знаний и фасад ретрива по ним (задача 34).
    let knowledgeBaseStore: KnowledgeBaseStore
    let knowledgeBaseManager: KnowledgeBaseManager
    /// Пайплайны (задача 36): стор, движок прогонов, cron-планировщик, PR-watch.
    let pipelineStore: PipelineStore
    let pipelineEngine: PipelineEngine
    let pipelineScheduler: PipelineScheduler
    let prWatcher: PRWatcher
    /// Code review (задача 37): общий раннер /review, пресета и локального диффа.
    let codeReviewRunner: CodeReviewRunner
    /// Тюнинг локальных LLM (задача 81): датасеты и прогоны CLI-тулчейна finetune/
    /// поверх репозитория из ProjectToolsProvider.currentRepoRoot() — своей настройки нет.
    let fineTuneStore: FineTuneStore
    let fineTuneRunner: FineTuneRunner
    let fineTuneViewModel: FineTuneViewModel
    /// Мини-чат оценки уверенности (задача 85): `mlx_lm.server` — управляемый child-процесс,
    /// один на приложение (тюн/baseline и чат/батч исключены взаимным guard'ом по памяти).
    let mlxServerManager: MlxServerManager
    let tuningChatViewModel: TuningChatViewModel

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
        projectToolsProvider = ProjectToolsProvider(settingsStore: settingsStore, router: router)
        let knowledgeBaseStore = KnowledgeBaseStore()
        self.knowledgeBaseStore = knowledgeBaseStore
        knowledgeBaseManager = KnowledgeBaseManager(store: knowledgeBaseStore,
                                                    ragIndexManager: ragIndexManager,
                                                    projectToolsProvider: projectToolsProvider,
                                                    router: router)

        // Пайплайны (задача 36): движок гоняет прогоны поверх чатов,
        // планировщик и PR-watcher стартуют в wire() после подвязки мостов.
        let pipelineStore = PipelineStore()
        self.pipelineStore = pipelineStore
        let pipelineEngine = PipelineEngine(store: pipelineStore, chatViewModel: chatViewModel)
        self.pipelineEngine = pipelineEngine
        pipelineScheduler = PipelineScheduler(store: pipelineStore, engine: pipelineEngine)
        prWatcher = PRWatcher(store: pipelineStore, engine: pipelineEngine)
        codeReviewRunner = CodeReviewRunner(chatViewModel: chatViewModel,
                                            projectToolsProvider: projectToolsProvider,
                                            router: router)

        // Тюнинг (задача 81): корень — <projectRepoPath>/finetune, отдельной настройки
        // не заводим (ProjectToolsProvider уже резолвит projectRepoPath). ViewModel
        // сам @MainActor — замыкание в него безопасно; раннер — actor, ему передаём
        // снимок URL, обновляемый из wire() (updateRoot), а не замыкание на
        // MainActor-состояние (settingsStore читался бы с кооперативного пула).
        let toolsProviderForFineTune = projectToolsProvider
        let fineTuneRoot: () -> URL? = {
            toolsProviderForFineTune.currentRepoRoot()?.appendingPathComponent("finetune")
        }
        let fineTuneStore = FineTuneStore()
        self.fineTuneStore = fineTuneStore
        let fineTuneRunner = FineTuneRunner(fineTuneRoot: fineTuneRoot())
        self.fineTuneRunner = fineTuneRunner

        // Мини-чат тюнинга (задача 85): резолвер python привязан к реальному
        // fineTuneRoot (дефолт MlxServerManager бьёт в ~/finetune — здесь тот же
        // репозиторий, что и у остального раздела «Тюнинг»).
        let mlxServerManager = MlxServerManager(pythonResolver: {
            guard let root = fineTuneRoot() else { return nil }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = MCPEnv.augmentedPATH(extra: environment["PATH"] ?? "")
            let candidates = FineTuneEnvironment.candidates(fineTuneRoot: root, environment: environment)
            return await Task.detached { candidates.first { MlxServerManager.probeServerModule($0) } }.value
        })
        self.mlxServerManager = mlxServerManager

        fineTuneViewModel = FineTuneViewModel(store: fineTuneStore, runner: fineTuneRunner,
                                              fineTuneRoot: fineTuneRoot,
                                              criteriaProviders: { router.resolveChatProviders(for: .finetuneCriteria) },
                                              stopMlxServer: { [weak mlxServerManager] in mlxServerManager?.stopNow() })

        let fineTuneViewModelForChat = fineTuneViewModel
        tuningChatViewModel = TuningChatViewModel(
            server: mlxServerManager,
            dataset: { [weak fineTuneViewModelForChat] in
                fineTuneViewModelForChat?.datasets.first { $0.workdir == "meetings" }
            },
            runs: { [weak fineTuneStore] in fineTuneStore?.runs ?? [] },
            isTuneOrBaselineActive: { [weak fineTuneStore, weak fineTuneViewModelForChat] in
                (fineTuneStore?.runs.contains { $0.status == .running } ?? false)
                    || (fineTuneViewModelForChat?.isSnapshottingBaseline ?? false)
            },
            escalationResolver: { [weak registry] target in
                guard let registry else { return .unavailable(reason: "провайдер недоступен") }
                return EscalationTargetResolver.resolve(target: target, registry: registry)
            })

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

        // Смена репозитория проекта (задача 81): обновить снимок корня в раннере
        // (В4 — раннер не должен читать MainActor-состояние из своего актора) и
        // пересканировать датасеты тюнинга — finetune/ лежит внутри того же
        // репозитория, что и остальные project-инструменты. Срабатывает и сразу
        // на подписке — это же подхватывает прогон, оставленный «работать» в
        // прошлой сессии, без открытия раздела «Тюнинг».
        settingsStore.$settings
            .map(\.projectRepoPath)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                let root = self.projectToolsProvider.currentRepoRoot()?.appendingPathComponent("finetune")
                let runner = self.fineTuneRunner
                let viewModel = self.fineTuneViewModel
                Task { await runner.updateRoot(root) }
                Task { await viewModel.refreshDatasets() }
            }
            .store(in: &cancellables)

        // Мосты инструментов чата — здесь, а не в ContentView.onAppear
        // (задача 36): пайплайн, сработавший до первого открытия раздела
        // «Чат», иначе бежал бы без инструментов и RAG.
        wireChatBridges()
        // Code review (задача 37): раннер — обработчик /review в чате и
        // сборщик input пресета в движке (weak-ссылки, владелец — AppModel).
        chatViewModel.codeReviewRunner = codeReviewRunner
        pipelineEngine.reviewRunner = codeReviewRunner
        // Фоновые циклы пайплайнов — после подвязки мостов (catch-up на старте
        // может сразу запустить прогон). Гашение — по willTerminate внутри.
        pipelineScheduler.start()
        prWatcher.start()

        // Диалог выхода при живом прогоне тюнинга (задача 81): probe пересобирает
        // Active заново на каждый Cmd+Q — прогресс должен быть свежим в этот момент.
        FineTuneQuitGuard.probe = { [weak fineTuneStore, weak fineTuneRunner] in
            guard let store = fineTuneStore, let runner = fineTuneRunner,
                  let run = FineTuneQuitGuard.activeRun(in: store.runs) else { return nil }
            let iter = run.points.last?.iter ?? 0
            return FineTuneQuitGuard.Active(
                datasetTitle: run.datasetTitle,
                progress: "iter \(iter)/\(run.hyperparameters.iters)",
                stop: { FineTuneQuitGuard.waitFor { await runner.stop(workdir: run.workdir) } },
                detach: { FineTuneQuitGuard.waitFor { await runner.detachAllFromQuit() } })
        }
    }

    // MARK: - Мосты чата (задачи 14, 15, 21, 34)

    /// Все четыре моста — однократно (guard == nil сохраняет идемпотентность
    /// на случай повторного вызова).
    private func wireChatBridges() {
        wireRagProvider()
        wireRagTool()
        wireMCPBridge()
        wireProjectTools()
    }

    /// Связка чата с RAG (задачи 14, 34): статический ретрив (фолбэк без
    /// tool-calling) идёт через фасад реестра баз; rewrite/rerank используют
    /// тот же чат-роутер (только чисто-vault путь).
    private func wireRagProvider() {
        guard chatViewModel.ragProvider == nil else { return }
        chatViewModel.ragProvider = { [weak knowledgeBaseManager,
                                       weak functionRouter] chat, query in
            guard let manager = knowledgeBaseManager else { return nil }
            let needsLLM = chat.configuration.ragQueryRewrite || chat.configuration.ragRerankEnabled
            // Задача 28: у реранка/переписывания своя функция роутинга.
            let chatProvider = needsLLM ? functionRouter?.resolveChatProvider(for: .ragRerank) : nil
            return await manager.retrieve(enabledIDs: chat.configuration.enabledKnowledgeBaseIDs,
                                          query: query,
                                          history: chat.messages,
                                          configuration: chat.configuration,
                                          chatProvider: chatProvider)
        }
    }

    /// Связка чата с инструментом rag_search (задача 34): определение по
    /// включённым базам чата и исполнитель поиска.
    private func wireRagTool() {
        guard chatViewModel.ragToolBridge == nil else { return }
        let manager = knowledgeBaseManager
        chatViewModel.ragToolBridge = ChatViewModel.RagToolBridge(
            definition: { enabledIDs in
                manager.toolDefinition(enabledIDs: enabledIDs)
            },
            execute: { args, enabledIDs, topK, minScore in
                await manager.executeSearchTool(argumentsJSON: args,
                                                enabledIDs: enabledIDs,
                                                topK: topK,
                                                minScore: minScore)
            })
    }

    /// Связка чата с MCP (задача 15): инструменты включённых серверов и
    /// исполнитель вызовов.
    private func wireMCPBridge() {
        guard chatViewModel.mcpBridge == nil else { return }
        let manager = mcpServersViewModel.manager
        chatViewModel.mcpBridge = ChatViewModel.MCPBridge(
            tools: { [weak mcpServersViewModel] serverIDs in
                await mcpServersViewModel?.tools(for: serverIDs) ?? []
            },
            execute: { name, args in
                await manager.call(qualifiedName: name, argumentsJSON: args)
            })
    }

    /// Связка чата со встроенными инструментами проекта (задачи 21, 39):
    /// провайдер держит per-root исполнители — каждый чат может работать со
    /// своим каталогом (projectRootPath), глобальный путь настроек — дефолт.
    private func wireProjectTools() {
        guard chatViewModel.projectToolsBridge == nil else { return }
        let provider = projectToolsProvider
        chatViewModel.projectToolsBridge = ChatViewModel.ProjectToolsBridge(
            available: { rootOverride in
                provider.effectiveRootURL(override: rootOverride) != nil
            },
            tools: { rootOverride in
                provider.toolset(rootOverride: rootOverride)?.registry.definitions() ?? []
            },
            rootURL: { rootOverride in
                provider.effectiveRootURL(override: rootOverride)
            },
            execute: { rootOverride, name, args, fileOps in
                guard let toolset = provider.toolset(rootOverride: rootOverride) else {
                    return "ERROR: каталог проекта не выбран (чип «Проект» или Настройки → Инструменты)"
                }
                return await toolset.executor.execute(name: name, argumentsJSON: args,
                                                      fileOps: fileOps)
            })
        // /help (задачи 22, 25): RAG-ретрив по докам репозитория с фолбэком
        // на полный контекст — вся логика в ProjectToolsProvider.
        chatViewModel.projectDocsProvider = { question in
            await provider.helpContext(question: question)
        }
        // «Сделать базой знаний» (задача 39): каталог чата → папочная база
        // реестра (дедуп по пути в addFolder).
        chatViewModel.addFolderKnowledgeBase = { [weak knowledgeBaseStore] url in
            knowledgeBaseStore?.addFolder(url: url).id ?? ""
        }
        // Немедленная индексация добавленной базы (отклик UI): тот же
        // инкрементальный sync, что и при ленивом ретриве. nil — эмбеддера нет.
        let folderService = knowledgeBaseManager.folderService
        chatViewModel.indexFolderKnowledgeBase = { [weak functionRouter] url in
            guard let resolved = functionRouter?.resolveEmbeddingProvider(for: .embedding)
            else { return nil }
            let tag = "\(resolved.model)|\(resolved.provider.dimension)"
            return await folderService.buildIndex(root: url,
                                                  embedder: resolved.provider,
                                                  model: resolved.model,
                                                  tag: tag)?.chunks
        }
        // Вкладка «Изменения» (задача 40): git-обзор каталога чата, коммит,
        // пуш. GitClient создаётся на вызов — операции редкие и короткие,
        // а его FIFO-очередь важна лишь внутри одного вызова.
        chatViewModel.chatGitBridge = ChatViewModel.ChatGitBridge(
            overview: { rootOverride in
                guard let root = provider.effectiveRootURL(override: rootOverride)
                else { return nil }
                return await GitChangesOverview.load(git: GitClient(repoURL: root))
            },
            commit: { rootOverride, message in
                guard let root = provider.effectiveRootURL(override: rootOverride)
                else { return "каталог не задан" }
                do {
                    let committed = try await GitClient(repoURL: root)
                        .commitAll(message: message)
                    return committed ? nil : "нет изменений для коммита"
                } catch {
                    return (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            },
            push: { rootOverride in
                guard let root = provider.effectiveRootURL(override: rootOverride)
                else { return "каталог не задан" }
                do {
                    try await GitClient(repoURL: root).push()
                    return nil
                } catch {
                    return (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            },
            revertFile: { rootOverride, path in
                guard let root = provider.effectiveRootURL(override: rootOverride)
                else { return "каталог не задан" }
                return await GitRevert.revert(git: GitClient(repoURL: root),
                                              root: root, path: path)
            })
    }
}
