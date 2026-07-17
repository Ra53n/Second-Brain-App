// ChatViewModel.swift — состояние раздела «Чат» (задача 12).
//
// CRUD чатов, отправка через роутер (функция .chat; per-чат переопределение
// провайдера/модели), СТРИМИНГ ответа в UI (AsyncThrowingStream из 07/08),
// отмена генерации, ошибки в баннер. Персистентность — паттерн MA: debounce
// 300 мс на $chats (стриминг не пишет диск на каждый токен), синхронный сейв
// на willTerminate.
//
// Точки расширения: ragContextProvider (задача 14 подставит retrieval),
// toolsProvider (задача 15 — MCP-инструменты).

import AppKit
import Combine
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var selectedChatID: UUID?
    @Published var input: String = ""

    let router: FunctionRouter
    let registry: ProviderRegistry

    /// Ретрив задачи 14: (чат, вопрос) → блок [RAG_CONTEXT] + источники.
    /// Вызывается ТОЛЬКО при включённом тумблере «Отвечать по базе».
    var ragProvider: ((Chat, String) async -> RagRetrievalOutcome?)?

    /// MCP-мост (задача 15): инструменты включённых серверов чата и исполнитель.
    struct MCPBridge {
        var tools: (Set<UUID>) async -> [ToolDefinition]
        var execute: (String, String) async -> String
    }
    var mcpBridge: MCPBridge?

    /// Мост встроенных инструментов проекта (задача 21). Маршрутизация в
    /// send(): вызовы с именами из tools() идут сюда, остальные — в MCP
    /// (имена не пересекаются: MCP-имена всегда содержат «__»).
    struct ProjectToolsBridge {
        /// Репозиторий выбран в настройках (для видимости пункта меню).
        var available: () -> Bool
        var tools: () -> [ToolDefinition]
        var execute: (String, String) async -> String
    }
    var projectToolsBridge: ProjectToolsBridge?

    /// Доступны ли инструменты проекта прямо сейчас (для UI меню).
    var projectToolsAvailable: Bool {
        projectToolsBridge?.available() ?? false
    }

    /// Доступен ли провайдер чата прямо сейчас (per-чат override либо роутер) —
    /// шаг «Модель доступна» мастера настройки (задача 27).
    var chatProviderAvailable: Bool {
        guard let chat = selectedChat else { return false }
        return resolveProvider(for: chat) != nil
    }

    /// «DisplayName · model», который роутер выберет в режиме «Авто» —
    /// для тайтла пикера «Авто → …» (задача 29). nil — явный провайдер
    /// в конфиге чата либо провайдеров нет.
    var resolvedAutoDescription: String? {
        guard let chat = selectedChat, chat.configuration.providerID == nil,
              let resolved = resolveProvider(for: chat) else { return nil }
        return "\(resolved.displayName) · \(resolved.model)"
    }

    /// /help (задачи 22, 25): блок [PROJECT_DOCS] по вопросу пользователя —
    /// RAG-ретрив top-K чанков доков либо полный контекст (фолбэк).
    /// nil — репозиторий не настроен; пустая строка — доков в нём нет.
    var projectDocsProvider: ((String) async -> String?)?

    private let fileURL: URL
    private var saveCancellable: AnyCancellable?
    private var terminateObserver: NSObjectProtocol?
    /// Активные генерации по чату — для отмены.
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    init(router: FunctionRouter,
         registry: ProviderRegistry,
         fileURL: URL = ChatPersistence.defaultFileURL) {
        self.router = router
        self.registry = registry
        self.fileURL = fileURL

        let loaded = ChatPersistence.load(from: fileURL)
        if loaded.isEmpty {
            let first = Chat()
            chats = [first]
            selectedChatID = first.id
        } else {
            chats = loaded
            selectedChatID = loaded.first?.id
        }

        // Автосохранение: debounce гасит шквал обновлений при стриминге.
        saveCancellable = $chats
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [fileURL] chats in
                DispatchQueue.global(qos: .utility).async {
                    ChatPersistence.save(chats, to: fileURL)
                }
            }
        // Страховка на выход — пишем без debounce (willTerminate на главном потоке).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ChatPersistence.save(self.chats, to: self.fileURL)
            }
        }
    }

    // MARK: - CRUD

    var selectedChat: Chat? {
        selectedChatID.flatMap { id in chats.first { $0.id == id } }
    }

    private var selectedIndex: Int? {
        selectedChatID.flatMap { id in chats.firstIndex { $0.id == id } }
    }

    func newChat() {
        let chat = Chat()
        chats.insert(chat, at: 0)
        selectedChatID = chat.id
    }

    func deleteChat(_ id: UUID) {
        cancelGeneration(chatID: id)
        chats.removeAll { $0.id == id }
        if selectedChatID == id { selectedChatID = chats.first?.id }
    }

    func renameChat(_ id: UUID, to title: String) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        chats[index].title = trimmed.isEmpty ? chats[index].title : trimmed
    }

    /// Провайдеры с capability .chat для пикера модели (локальные помечены).
    var chatProviderOptions: [ProviderDescriptor] {
        registry.descriptors(supporting: .chat)
    }

    /// Выбор провайдера/модели для текущего чата (nil id — вернуться к роутеру).
    func setModel(providerID: ProviderID?, model: String?) {
        guard let index = selectedIndex else { return }
        chats[index].configuration.providerID = providerID
        chats[index].configuration.model = model
    }

    /// Тумблер «Отвечать по базе» текущего чата (persisted per-чат).
    var ragEnabledBinding: Bool {
        get { selectedChat?.configuration.ragEnabled ?? false }
        set {
            guard let index = selectedIndex else { return }
            chats[index].configuration.ragEnabled = newValue
        }
    }

    // Настройки RAG текущего чата (задача 23): биндинги по образцу
    // ragEnabledBinding — get с дефолтом, set в конфигурацию выбранного чата.

    var ragTopKBinding: Int {
        get { selectedChat?.configuration.ragTopK ?? ChatConfiguration().ragTopK }
        set {
            guard let index = selectedIndex else { return }
            chats[index].configuration.ragTopK = newValue
        }
    }

    var ragMinScoreBinding: Double {
        get { selectedChat?.configuration.ragMinScore ?? 0 }
        set {
            guard let index = selectedIndex else { return }
            chats[index].configuration.ragMinScore = newValue
        }
    }

    var ragRerankBinding: Bool {
        get { selectedChat?.configuration.ragRerankEnabled ?? false }
        set {
            guard let index = selectedIndex else { return }
            chats[index].configuration.ragRerankEnabled = newValue
        }
    }

    var ragQueryRewriteBinding: Bool {
        get { selectedChat?.configuration.ragQueryRewrite ?? false }
        set {
            guard let index = selectedIndex else { return }
            chats[index].configuration.ragQueryRewrite = newValue
        }
    }

    var canSend: Bool {
        guard let chat = selectedChat else { return false }
        return !chat.isLoading
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Отправка со стримингом

    /// Переопределения одного хода (задача 22): /help добавляет докблок,
    /// принудительно включает инструменты проекта и пропускает RAG.
    private struct TurnOverrides {
        /// Загрузить [PROJECT_DOCS] через projectDocsProvider.
        var wantsProjectDocs = false
        /// Инструменты проекта включаются независимо от настройки чата.
        var forceProjectTools = false
        /// RAG-ретрив пропускается (докблок заменяет его на этом ходу).
        var skipsRag = false
        /// Провайдер без function calling → ответ без инструментов, не ошибка.
        var allowsToolFallback = false
    }

    func send() {
        guard let index = selectedIndex else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chats[index].isLoading else { return }
        // Поле очищается здесь, а не в startGeneration: регенерация (задача 23)
        // переиспользует генерацию и не должна стирать черновик пользователя.
        input = ""

        // Слэш-команды (задача 22): перехват до обычного пути отправки.
        if let command = SlashCommand.parse(text) {
            handleSlashCommand(command, rawText: text, chatIndex: index)
            return
        }
        startGeneration(chatIndex: index, userText: text, overrides: TurnOverrides())
    }

    // MARK: - Регенерация (задача 23)

    /// Можно ли перегенерировать: последний — ответ ассистента, перед ним
    /// вопрос пользователя, генерация не идёт.
    var canRegenerate: Bool {
        guard let chat = selectedChat, !chat.isLoading,
              chat.messages.last?.role == .assistant,
              chat.messages.dropLast().last?.role == .user else { return false }
        return true
    }

    /// Удаляет последний ответ ассистента и генерирует заново по тому же
    /// вопросу. Слэш-команды повторяются своим путём (в т.ч. /help с доками).
    func regenerateLastAnswer() {
        guard canRegenerate, let index = selectedIndex,
              let userText = chats[index].messages.dropLast().last?.content else { return }
        // Убираем пару «вопрос + ответ»: путь генерации добавит вопрос заново.
        chats[index].messages.removeLast(2)
        if let command = SlashCommand.parse(userText) {
            handleSlashCommand(command, rawText: userText, chatIndex: index)
        } else {
            startGeneration(chatIndex: index, userText: userText, overrides: TurnOverrides())
        }
    }

    /// Обработка слэш-команды: /help с вопросом идёт обычным генерационным
    /// путём с переопределениями хода; usage и незнакомая команда отвечаются
    /// локально, без вызова LLM.
    private func handleSlashCommand(_ command: SlashCommand, rawText: String, chatIndex: Int) {
        switch command {
        case .help:
            startGeneration(chatIndex: chatIndex, userText: rawText,
                            overrides: TurnOverrides(wantsProjectDocs: true,
                                                     forceProjectTools: true,
                                                     skipsRag: true,
                                                     allowsToolFallback: true))
        case .helpUsage:
            appendLocalExchange(chatIndex: chatIndex, userText: rawText,
                                assistantText: SlashCommand.usageText())
        case .unknown(let name):
            appendLocalExchange(chatIndex: chatIndex, userText: rawText,
                                assistantText: SlashCommand.usageText(unknownCommand: name))
        }
    }

    /// Локальный обмен без LLM: вопрос пользователя + мгновенный ответ
    /// ассистента (подсказки слэш-команд). isLoading не включается.
    private func appendLocalExchange(chatIndex: Int, userText: String, assistantText: String) {
        if !chats[chatIndex].messages.contains(where: { $0.role == .user }) {
            chats[chatIndex].title = Chat.makeTitle(from: userText)
        }
        chats[chatIndex].errorText = nil
        chats[chatIndex].messages.append(ChatMessage(role: .user, content: userText))
        chats[chatIndex].messages.append(ChatMessage(role: .assistant, content: assistantText))
        ChatPersistence.save(chats, to: fileURL)
    }

    /// Ошибки /help-хода (задача 22).
    enum SlashHelpError: LocalizedError {
        case repositoryNotConfigured

        var errorDescription: String? {
            "Репозиторий проекта не выбран: Настройки → «Инструменты»."
        }
    }

    /// Ядро генерации (бывшее тело send): добавляет сообщение пользователя и
    /// заглушку ассистента, строит запрос (RAG/доки/инструменты по overrides)
    /// и стримит либо гоняет tool-цикл. Семантика истории неизменна с задачи 12.
    private func startGeneration(chatIndex index: Int, userText text: String,
                                 overrides: TurnOverrides) {
        let chatID = chats[index].id

        // Автоназвание — из первого сообщения пользователя.
        if !chats[index].messages.contains(where: { $0.role == .user }) {
            chats[index].title = Chat.makeTitle(from: text)
        }
        chats[index].errorText = nil
        chats[index].messages.append(ChatMessage(role: .user, content: text))

        guard let resolved = resolveProvider(for: chats[index]) else {
            // Подсказка пути решения (задача 24): без неё пользователь не
            // находит, куда прописать ключ или где запустить локальную модель.
            let base = LLMError.providerUnavailable(
                chats[index].configuration.providerID ?? "chat").errorDescription ?? ""
            chats[index].errorText = base
                + " Ключи облачных провайдеров — Настройки → «Провайдеры», запуск локальных моделей — Настройки → «Локальные модели»."
            return
        }

        chats[index].isLoading = true
        // Заглушка ассистента: стриминг дописывает её содержимое по кускам.
        let placeholderID = UUID()
        var placeholder = ChatMessage(role: .assistant, content: "")
        placeholder.id = placeholderID
        chats[index].messages.append(placeholder)

        let configuration = chats[index].configuration
        let history = Array(chats[index].messages.dropLast(2).suffix(configuration.historyWindow))
            + [ChatMessage(role: .user, content: text)]
        let chatSnapshot = chats[index]

        generationTasks[chatID] = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            do {
                // Ретрив (задача 14): только при включённом тумблере;
                // /help-ход пропускает RAG — его контекст заменяют доки.
                var retrieval: RagRetrievalOutcome?
                if chatSnapshot.configuration.ragEnabled && !overrides.skipsRag {
                    retrieval = await self.ragProvider?(chatSnapshot, text)
                    if let sources = retrieval?.sources, !sources.isEmpty {
                        self.attachSources(chatID: chatID, messageID: placeholderID,
                                           sources: sources)
                    }
                }

                // Документация проекта (задача 22): только для /help-хода.
                var projectDocs: String?
                if overrides.wantsProjectDocs {
                    guard let docs = await self.projectDocsProvider?(text) else {
                        throw SlashHelpError.repositoryNotConfigured
                    }
                    // Репозиторий без README/docs — честно говорим модели.
                    projectDocs = docs.isEmpty
                        ? "(в репозитории нет README и docs/ — изучай проект инструментами list_files/read_file)"
                        : docs
                }

                let messages = ChatPromptBuilder.requestMessages(
                    history: history,
                    historyWindow: configuration.historyWindow,
                    ragContext: retrieval?.block,
                    projectDocs: projectDocs)
                var settings = ChatSettings(model: resolved.model)
                settings.temperature = configuration.temperature

                // Инструменты (задачи 15, 21): MCP-серверы чата + встроенные
                // инструменты проекта → tool-use цикл БЕЗ стриминга (ответ
                // приходит целиком после вызовов).
                var tools: [ToolDefinition] = []
                if !chatSnapshot.configuration.enabledMCPServerIDs.isEmpty, let bridge = self.mcpBridge {
                    tools = await bridge.tools(chatSnapshot.configuration.enabledMCPServerIDs)
                }
                // Имена project-инструментов вычисляются на этот ход: по ним
                // executor-замыкание маршрутизирует вызовы между мостами.
                var projectNames: Set<String> = []
                if chatSnapshot.configuration.projectToolsEnabled || overrides.forceProjectTools,
                   let project = self.projectToolsBridge {
                    let projectTools = project.tools()
                    projectNames = Set(projectTools.map(\.name))
                    tools += projectTools
                }
                // Итоговый usage хода (задача 29): стрим отдаёт событием,
                // tool-цикл суммирует по итерациям.
                var turnUsage: ChatUsage?
                if !tools.isEmpty, let toolProvider = resolved.provider as? ToolCapableChatProvider {
                    let mcpBridge = self.mcpBridge
                    let projectBridge = self.projectToolsBridge
                    let outcome = try await ToolUseLoop.run(
                        provider: toolProvider,
                        settings: settings,
                        messages: messages.map(ToolAwareMessage.init),
                        tools: tools,
                        execute: { name, args in
                            if projectNames.contains(name), let projectBridge {
                                return await projectBridge.execute(name, args)
                            }
                            guard let mcpBridge else {
                                return "ERROR: исполнитель инструмента «\(name)» недоступен"
                            }
                            return await mcpBridge.execute(name, args)
                        })
                    self.appendToMessage(chatID: chatID, messageID: placeholderID,
                                         chunk: outcome.text)
                    self.attachToolCalls(chatID: chatID, messageID: placeholderID,
                                         calls: outcome.transcript)
                    turnUsage = outcome.usage
                } else {
                    // Провайдер без function calling при запрошенных инструментах:
                    // обычный чат — ошибка (задача 15), /help деградирует до
                    // ответа по докам без инструментов.
                    if !tools.isEmpty && !overrides.allowsToolFallback {
                        throw MCPError.toolsUnsupportedByProvider
                    }
                    for try await event in resolved.provider.stream(messages, settings: settings) {
                        switch event {
                        case .text(let chunk):
                            self.appendToMessage(chatID: chatID, messageID: placeholderID, chunk: chunk)
                        case .usage(let usage):
                            turnUsage = usage
                        }
                    }
                }
                self.finishGeneration(chatID: chatID, messageID: placeholderID,
                                      duration: Date().timeIntervalSince(start),
                                      usage: turnUsage, resolved: resolved, error: nil)
            } catch is CancellationError {
                self.finishGeneration(chatID: chatID, messageID: placeholderID,
                                      duration: Date().timeIntervalSince(start),
                                      usage: nil, resolved: resolved, error: nil)
            } catch {
                self.finishGeneration(chatID: chatID, messageID: placeholderID,
                                      duration: Date().timeIntervalSince(start),
                                      usage: nil, resolved: resolved, error: error)
            }
            self.generationTasks[chatID] = nil
        }
    }

    /// Отмена генерации: частичный ответ остаётся в истории.
    func cancelGeneration(chatID: UUID) {
        generationTasks[chatID]?.cancel()
        generationTasks[chatID] = nil
    }

    // MARK: - Внутренности

    /// Провайдер: per-чат переопределение (если валидно) → роутер функции .chat.
    private func resolveProvider(for chat: Chat) -> ResolvedChatProvider? {
        if let providerID = chat.configuration.providerID,
           registry.isAvailable(providerID),
           let provider = registry.chatProvider(for: providerID) {
            let descriptor = registry.descriptor(for: providerID)
            let model = chat.configuration.model ?? descriptor?.defaultModel
            if let model {
                return ResolvedChatProvider(provider: provider, model: model,
                                            providerID: providerID,
                                            displayName: descriptor?.displayName
                                                ?? providerID.rawValue)
            }
        }
        return router.resolveChatProvider(for: .chat)
    }

    private func appendToMessage(chatID: UUID, messageID: UUID, chunk: String) {
        guard let chatIndex = chats.firstIndex(where: { $0.id == chatID }),
              let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        chats[chatIndex].messages[messageIndex].content += chunk
    }

    private func attachSources(chatID: UUID, messageID: UUID, sources: [RagSource]) {
        guard let chatIndex = chats.firstIndex(where: { $0.id == chatID }),
              let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        chats[chatIndex].messages[messageIndex].sources = sources
    }

    private func attachToolCalls(chatID: UUID, messageID: UUID, calls: [ToolCallDisplay]) {
        guard !calls.isEmpty,
              let chatIndex = chats.firstIndex(where: { $0.id == chatID }),
              let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        chats[chatIndex].messages[messageIndex].toolCalls = calls
    }

    /// Тумблер встроенных инструментов проекта для текущего чата (задача 21).
    func toggleProjectTools() {
        guard let index = selectedIndex else { return }
        chats[index].configuration.projectToolsEnabled.toggle()
    }

    /// Тумблер MCP-сервера для текущего чата.
    func toggleMCPServer(_ id: UUID) {
        guard let index = selectedIndex else { return }
        if chats[index].configuration.enabledMCPServerIDs.contains(id) {
            chats[index].configuration.enabledMCPServerIDs.remove(id)
        } else {
            chats[index].configuration.enabledMCPServerIDs.insert(id)
        }
    }

    private func finishGeneration(chatID: UUID, messageID: UUID,
                                  duration: TimeInterval,
                                  usage: ChatUsage?,
                                  resolved: ResolvedChatProvider?,
                                  error: Error?) {
        guard let chatIndex = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[chatIndex].isLoading = false
        guard let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        let isEmpty = chats[chatIndex].messages[messageIndex].content.isEmpty
        if let error {
            chats[chatIndex].errorText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        if isEmpty {
            // Пустая заглушка (ошибка до первого токена / мгновенная отмена) — убираем.
            chats[chatIndex].messages.remove(at: messageIndex)
        } else {
            // Метрики хода (задача 29): токены и фактическая модель ответа.
            chats[chatIndex].messages[messageIndex].metrics = MessageMetrics(
                promptTokens: usage?.promptTokens,
                completionTokens: usage?.completionTokens,
                totalTokens: usage?.totalTokens,
                duration: duration,
                providerID: resolved?.providerID.rawValue,
                providerName: resolved?.displayName,
                model: resolved?.model)
        }
        // Немедленная запись финального состояния (debounce мог не успеть).
        ChatPersistence.save(chats, to: fileURL)
    }
}
