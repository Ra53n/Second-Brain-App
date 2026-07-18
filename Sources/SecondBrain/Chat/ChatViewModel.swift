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

    /// Мост встроенных инструментов проекта (задачи 21, 39). Маршрутизация в
    /// send(): вызовы с именами из tools() идут сюда, остальные — в MCP
    /// (имена не пересекаются: MCP-имена всегда содержат «__»). Первый
    /// параметр всюду — projectRootPath чата (nil = глобальная настройка).
    struct ProjectToolsBridge {
        /// Каталог задан (override чата либо настройки) — видимость меню.
        var available: (String?) -> Bool
        var tools: (String?) -> [ToolDefinition]
        /// Эффективный корень (для превью diff'ов и директивы промпта).
        var rootURL: (String?) -> URL?
        /// (rootOverride, имя, аргументы, файловый контекст чата) → результат.
        var execute: (String?, String, String, FileOpsContext?) async -> String
    }
    var projectToolsBridge: ProjectToolsBridge?

    // Слой разрешений (задача 39). Хранимые свойства — здесь (extension не
    // может), логика — в ToolApprovalCenter.swift.
    /// Ожидающие подтверждения операции (карточка над полем ввода).
    @Published var pendingToolApprovals: [PendingToolApproval] = []
    /// Continuation'ы ожидающих гейтов по id запроса.
    var approvalContinuations: [UUID: CheckedContinuation<ToolApprovalDecision, Never>] = [:]
    /// «Разрешить на сессию»: ключи операций по чату (in-memory, до выхода).
    var sessionApprovals: [UUID: Set<String>] = [:]
    /// Контексты файловых операций по чату (реестр чтений, изменения хода).
    var fileOpsContexts: [UUID: FileOpsContext] = [:]
    /// Мост «каталог чата → папочная база знаний» (задача 39, подвязывает
    /// AppModel к KnowledgeBaseStore.addFolder). Возвращает id базы.
    var addFolderKnowledgeBase: ((URL) -> String)?

    /// Раннер code review (задача 37) — обработчик /review. weak: раннер
    /// держит ChatViewModel строго, владелец обоих — AppModel.
    weak var codeReviewRunner: CodeReviewRunner?

    /// Диалог превью постинга ревью в PR (item-based sheet, паттерн
    /// titleDialog встреч). non-nil → шит открыт.
    struct ReviewPostContext: Identifiable {
        let messageID: UUID
        let target: ReviewTarget
        /// Предзаполненный текст комментария (content сообщения), редактируемый.
        var body: String
        var id: UUID { messageID }
    }
    @Published var reviewPostDialog: ReviewPostContext?

    /// Открыть превью постинга для итогового сообщения ревью.
    func openReviewPostDialog(for message: ChatMessage) {
        guard let target = message.reviewTarget else { return }
        reviewPostDialog = ReviewPostContext(messageID: message.id,
                                             target: target,
                                             body: message.content)
    }

    /// Есть ли GitHub-токен (disabled-состояние кнопки отправки в шите).
    var reviewPostTokenAvailable: Bool {
        codeReviewRunner?.hasToken ?? false
    }

    /// Постинг из шита. nil — успех (диалог закрыт, сообщение помечено
    /// «Отправлено ✓»); текст — ошибка, шит остаётся открытым.
    func submitReviewPost(body: String, context: ReviewPostContext) async -> String? {
        guard let runner = codeReviewRunner else { return "Code review недоступен." }
        do {
            try await runner.post(target: context.target, body: body,
                                  messageID: context.messageID)
            reviewPostDialog = nil
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Мост rag_search (задача 34): определение инструмента по включённым
    /// базам чата и исполнитель поиска (KnowledgeBaseManager). Отдельно от
    /// ragProvider: тот — статическая подстановка, этот — tool-режим.
    struct RagToolBridge {
        /// nil — включённых баз нет, инструмент не предлагается.
        var definition: (Set<String>) -> ToolDefinition?
        /// (аргументы вызова, включённые базы, topK, minScore) → текст + источники.
        var execute: (String, Set<String>, Int, Double) async -> RagToolOutcome
    }
    var ragToolBridge: RagToolBridge?

    /// Доступны ли инструменты проекта прямо сейчас (для UI меню):
    /// учитывает per-chat каталог текущего чата (задача 39).
    var projectToolsAvailable: Bool {
        projectToolsBridge?.available(selectedChat?.configuration.projectRootPath) ?? false
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

    // FSM-прогоны (задача 35). Хранимые свойства — здесь (extension не может),
    // оркестратор — в ChatViewModel+AgentRun.swift.
    /// Поколение прогона на чат: каждый старт инкрементит. Старый (отменённый)
    /// Task, доигрывая отмену, сверяет поколение и НЕ трогает чужое состояние.
    var agentGen: [UUID: Int] = [:]
    /// Активные FSM-прогоны по чату — для паузы/отмены.
    var agentTasks: [UUID: Task<Void, Never>] = [:]

    init(router: FunctionRouter,
         registry: ProviderRegistry,
         fileURL: URL = ChatPersistence.defaultFileURL) {
        self.router = router
        self.registry = registry
        self.fileURL = fileURL

        var loaded = ChatPersistence.load(from: fileURL)
        // Normalize FSM-прогонов (задача 35, паттерн MeetingStore): зависшие
        // «running» после краша/рестарта → paused, кнопка «Продолжить».
        for i in loaded.indices where loaded[i].agentContext?.status == .running {
            loaded[i].agentContext?.status = .paused
        }
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
        // FSM-прогон (задача 35): гасим Task и поднимаем поколение — доигрывающий
        // Task выйдет по сверке, не тронув чужое состояние.
        agentTasks[id]?.cancel()
        agentTasks[id] = nil
        agentGen[id] = (agentGen[id] ?? 0) + 1
        // Слой разрешений (задача 39): ожидания гейта отклоняются, состояние чата чистится.
        denyPendingApprovals(chatID: id)
        sessionApprovals[id] = nil
        fileOpsContexts[id] = nil
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

    /// Реальные модели одного ДОСТУПНОГО провайдера — секция пикера (задача 32).
    struct ProviderModelChoices: Identifiable {
        let descriptor: ProviderDescriptor
        let models: [String]
        var id: ProviderID { descriptor.id }
    }

    /// Кураторские списки моделей облачных провайдеров (задача 32): актуальные
    /// чат-модели на 2026-07; произвольная строка — через «Своя модель…».
    static let curatedChatModels: [ProviderID: [String]] = [
        "openai": ["gpt-4o-mini", "gpt-4o", "o3-mini"],
        "gemini": ["gemini-2.0-flash", "gemini-2.5-flash", "gemini-2.5-pro"],
        "deepseek": ["deepseek-chat", "deepseek-reasoner"],
        "openrouter": ["deepseek/deepseek-chat", "deepseek/deepseek-r1",
                       "openai/gpt-4o-mini", "anthropic/claude-sonnet-4"]
    ]

    /// Только ДОСТУПНЫЕ провайдеры с реальными списками моделей (задача 32):
    /// нет ключа/рантайма — провайдера в пикере нет вообще; Ollama отдаёт
    /// фактически установленные чат-модели из /api/tags.
    func availableModelChoices() async -> [ProviderModelChoices] {
        var result: [ProviderModelChoices] = []
        for descriptor in registry.descriptors(supporting: .chat)
        where registry.isAvailable(descriptor.id) {
            if let ollama = registry.chatProvider(for: descriptor.id) as? OllamaProvider {
                // Установленные модели; сервер лежит/пуст → секции нет (честно).
                let installed = (try? await ollama.client.installedModels()) ?? []
                let chatModels = installed.filter(\.supportsChat).map(\.name)
                if !chatModels.isEmpty {
                    result.append(ProviderModelChoices(descriptor: descriptor,
                                                       models: chatModels))
                }
                continue
            }
            let curated = Self.curatedChatModels[descriptor.id]
                ?? descriptor.defaultModel.map { [$0] } ?? []
            if !curated.isEmpty {
                result.append(ProviderModelChoices(descriptor: descriptor, models: curated))
            }
        }
        return result
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

    /// Включённые базы знаний текущего чата (задача 34).
    var enabledKnowledgeBaseIDs: Set<String> {
        selectedChat?.configuration.enabledKnowledgeBaseIDs ?? [KnowledgeBase.vaultID]
    }

    /// Тумблер базы в чипе «База» (мультивыбор per-чат).
    func toggleKnowledgeBase(_ id: String) {
        guard let index = selectedIndex else { return }
        if chats[index].configuration.enabledKnowledgeBaseIDs.contains(id) {
            chats[index].configuration.enabledKnowledgeBaseIDs.remove(id)
        } else {
            chats[index].configuration.enabledKnowledgeBaseIDs.insert(id)
        }
    }

    /// Тумблер «RAG как инструмент» текущего чата (задача 34).
    var ragAsToolBinding: Bool {
        get { selectedChat?.configuration.ragAsTool ?? true }
        set {
            guard let index = selectedIndex else { return }
            chats[index].configuration.ragAsTool = newValue
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
        // «Полный проход (FSM)» (задача 35): вместо одного запроса — прогон
        // planning → execution → validation → answer.
        if chats[index].configuration.agentModeEnabled {
            startAgentRun(chatIndex: index, userText: text)
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
        case .review(let argument):
            handleReviewCommand(argument: argument, rawText: rawText, chatIndex: chatIndex)
        case .unknown(let name):
            appendLocalExchange(chatIndex: chatIndex, userText: rawText,
                                assistantText: SlashCommand.usageText(unknownCommand: name))
        }
    }

    /// /review (задача 37): пустой аргумент/мусор — usage локально; «local» —
    /// незакоммиченные изменения репо; иначе — PR по ссылке. Валидный target
    /// всегда идёт полным FSM-проходом (независимо от тумблера чата).
    private func handleReviewCommand(argument: String, rawText: String, chatIndex: Int) {
        guard let runner = codeReviewRunner else {
            appendLocalExchange(chatIndex: chatIndex, userText: rawText,
                                assistantText: "Code review недоступен: раннер не подключён.")
            return
        }
        if argument.isEmpty {
            appendLocalExchange(chatIndex: chatIndex, userText: rawText,
                                assistantText: SlashCommand.reviewUsageText())
            return
        }
        // Сжатие большого диффа — той же моделью, что поведёт FSM в этом чате.
        let condenseProvider = resolveProvider(for: chats[chatIndex])
        if argument.lowercased() == "local" {
            startReviewRun(rawText: rawText, chatIndex: chatIndex) {
                try await runner.prepareLocalInput(condenseProvider: condenseProvider)
            }
            return
        }
        guard let reference = PRReference.parse(argument) else {
            appendLocalExchange(chatIndex: chatIndex, userText: rawText,
                                assistantText: SlashCommand.reviewUsageText(
                                    problem: "Не удалось разобрать «\(argument)»."))
            return
        }
        startReviewRun(rawText: rawText, chatIndex: chatIndex) {
            try await runner.prepareInput(reference: reference,
                                          condenseProvider: condenseProvider)
        }
    }

    /// Асинхронная часть /review: isLoading лочит чат на время fetch (иначе
    /// повторный send успел бы до старта FSM); КАЖДАЯ ветка ошибки обязана
    /// его снять, иначе чат зависнет заблокированным.
    private func startReviewRun(rawText: String, chatIndex: Int,
                                prepare: @escaping () async throws -> CodeReviewRunner.PreparedReview) {
        let chatID = chats[chatIndex].id
        chats[chatIndex].errorText = nil
        chats[chatIndex].isLoading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await prepare()
                guard let index = self.chats.firstIndex(where: { $0.id == chatID }) else { return }
                // startAgentRun сам включит isLoading; снимаем свой лок.
                self.chats[index].isLoading = false
                await self.codeReviewRunner?.runReview(prepared: prepared, chatIndex: index)
            } catch {
                guard let index = self.chats.firstIndex(where: { $0.id == chatID }) else { return }
                self.chats[index].isLoading = false
                self.appendLocalExchange(
                    chatIndex: index, userText: rawText,
                    assistantText: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription)
            }
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
        // Промежуточные сообщения FSM-прогонов (план/шаги/проверка) — шум для
        // последующих ходов: в окно истории идут только реплики пользователя
        // и финальные ответы (задача 35, паттерн dialogContext MA).
        let history = Array(chats[index].messages.dropLast(2)
            .filter { $0.agentState == nil || $0.agentState == .answer }
            .suffix(configuration.historyWindow))
            + [ChatMessage(role: .user, content: text)]
        let chatSnapshot = chats[index]

        // RAG как инструмент (задача 34): tool-провайдер получает rag_search
        // и сам решает, когда искать; статический ретрив на этом ходу не нужен.
        let ragToolDefinition: ToolDefinition? = {
            guard configuration.ragEnabled, configuration.ragAsTool, !overrides.skipsRag,
                  resolveProvider(for: chatSnapshot)?.provider is ToolCapableChatProvider
            else { return nil }
            return ragToolBridge?.definition(configuration.enabledKnowledgeBaseIDs)
        }()

        generationTasks[chatID] = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            // Файловый контекст хода (задача 39): изменения цепляются к
            // сообщению и при ошибке/отмене — применённое не теряется из истории.
            var turnFileOps: FileOpsContext?
            do {
                // Ретрив (задача 14): только при включённом тумблере;
                // /help-ход пропускает RAG — его контекст заменяют доки;
                // tool-режим (задача 34) заменяет подстановку инструментом.
                var retrieval: RagRetrievalOutcome?
                if chatSnapshot.configuration.ragEnabled && !overrides.skipsRag
                    && ragToolDefinition == nil {
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

                // Инструменты (задачи 15, 21, 34, 39): единая сборка и
                // маршрутизация (ChatToolAssembly) → tool-use цикл БЕЗ
                // стриминга (ответ приходит целиком после вызовов). Источники
                // rag_search цепляются к сообщению сразу — цитаты видны ещё
                // в ходе цикла. Сборка ДО промпта: директива файловых
                // инструментов зависит от эффективного корня и режима.
                let tooling = await self.assembleTooling(
                    chatID: chatID,
                    configuration: chatSnapshot.configuration,
                    ragToolDefinition: ragToolDefinition,
                    forceProjectTools: overrides.forceProjectTools,
                    onRagSources: { sources in
                        self.appendSources(chatID: chatID, messageID: placeholderID,
                                           new: sources)
                    })
                turnFileOps = tooling.fileOps

                // Директивы [TOOLS] системного промпта: rag_search и файловые
                // инструменты (задача 39) — только когда они реально в ходе.
                var toolDirectives: [String] = []
                if ragToolDefinition != nil {
                    toolDirectives.append(ChatPromptBuilder.ragToolDirective)
                }
                if let projectRoot = tooling.projectRoot {
                    toolDirectives.append(ChatPromptBuilder.fileToolsDirective(
                        mode: chatSnapshot.configuration.permissionMode,
                        rootPath: projectRoot.path))
                }
                let messages = ChatPromptBuilder.requestMessages(
                    history: history,
                    historyWindow: configuration.historyWindow,
                    ragContext: retrieval?.block,
                    projectDocs: projectDocs,
                    tools: toolDirectives.isEmpty
                        ? nil : toolDirectives.joined(separator: "\n\n"))
                var settings = ChatSettings(model: resolved.model)
                settings.temperature = configuration.temperature

                let tools = tooling.tools
                // Итоговый usage хода (задача 29): стрим отдаёт событием,
                // tool-цикл суммирует по итерациям.
                var turnUsage: ChatUsage?
                if !tools.isEmpty, let toolProvider = resolved.provider as? ToolCapableChatProvider {
                    let outcome = try await ToolUseLoop.run(
                        provider: toolProvider,
                        settings: settings,
                        messages: messages.map(ToolAwareMessage.init),
                        tools: tools,
                        maxIterations: tooling.maxIterations,
                        execute: tooling.execute)
                    self.appendToMessage(chatID: chatID, messageID: placeholderID,
                                         chunk: outcome.text)
                    self.attachToolCalls(chatID: chatID, messageID: placeholderID,
                                         calls: outcome.transcript)
                    if let ops = tooling.fileOps {
                        self.attachFileChanges(chatID: chatID, messageID: placeholderID,
                                               changes: await ops.drainChanges())
                    }
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
                // Применённые до отмены файловые операции — в историю (39).
                if let ops = turnFileOps {
                    self.attachFileChanges(chatID: chatID, messageID: placeholderID,
                                           changes: await ops.drainChanges())
                }
                self.finishGeneration(chatID: chatID, messageID: placeholderID,
                                      duration: Date().timeIntervalSince(start),
                                      usage: nil, resolved: resolved, error: nil)
            } catch {
                if let ops = turnFileOps {
                    self.attachFileChanges(chatID: chatID, messageID: placeholderID,
                                           changes: await ops.drainChanges())
                }
                self.finishGeneration(chatID: chatID, messageID: placeholderID,
                                      duration: Date().timeIntervalSince(start),
                                      usage: nil, resolved: resolved, error: error)
            }
            self.generationTasks[chatID] = nil
        }
    }

    /// Одиночный ход до завершения для движка пайплайнов (задача 36): обычная
    /// генерация + ожидание её Task. Возвращает errorText чата после хода
    /// (nil = успех). Переопределения хода не нужны — пайплайн управляет
    /// инструментами через конфигурацию destination-чата.
    func runSingleTurnToCompletion(chatIndex index: Int, userText text: String) async -> String? {
        let chatID = chats[index].id
        startGeneration(chatIndex: index, userText: text, overrides: TurnOverrides())
        // Провайдер недоступен → Task не создан, errorText уже проставлен.
        await generationTasks[chatID]?.value
        return chats.first { $0.id == chatID }?.errorText
    }

    /// Отмена генерации: частичный ответ остаётся в истории.
    func cancelGeneration(chatID: UUID) {
        generationTasks[chatID]?.cancel()
        generationTasks[chatID] = nil
    }

    // MARK: - Внутренности

    /// Провайдер: per-чат переопределение (если валидно) → роутер функции .chat.
    /// Не private: FSM-оркестратор (ChatViewModel+AgentRun) резолвит так же.
    func resolveProvider(for chat: Chat) -> ResolvedChatProvider? {
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

    /// Добавление источников из rag_search (задача 34): модель может звать
    /// поиск несколько раз за цикл — источники накапливаются с дедупом по id
    /// (повтор оставляет лучший score).
    private func appendSources(chatID: UUID, messageID: UUID, new: [RagSource]) {
        guard !new.isEmpty,
              let chatIndex = chats.firstIndex(where: { $0.id == chatID }),
              let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        var merged = chats[chatIndex].messages[messageIndex].sources ?? []
        for source in new {
            if let existing = merged.firstIndex(where: { $0.id == source.id }) {
                merged[existing].score = max(merged[existing].score, source.score)
            } else {
                merged.append(source)
            }
        }
        chats[chatIndex].messages[messageIndex].sources = merged
    }

    private func attachToolCalls(chatID: UUID, messageID: UUID, calls: [ToolCallDisplay]) {
        guard !calls.isEmpty,
              let chatIndex = chats.firstIndex(where: { $0.id == chatID }),
              let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        chats[chatIndex].messages[messageIndex].toolCalls = calls
    }

    /// Применённые файловые операции хода (задача 39) — diff'ы в сообщение.
    func attachFileChanges(chatID: UUID, messageID: UUID, changes: [FileChangeDisplay]) {
        guard !changes.isEmpty,
              let chatIndex = chats.firstIndex(where: { $0.id == chatID }),
              let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        let existing = chats[chatIndex].messages[messageIndex].fileChanges ?? []
        chats[chatIndex].messages[messageIndex].fileChanges = existing + changes
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

        // Сообщение с tool-транскриптом при пустом тексте не выбрасываем:
        // вызовы инструментов — тоже результат хода (задача 35). Аналогично
        // применённые файловые операции (задача 39) — они уже на диске.
        let isEmpty = chats[chatIndex].messages[messageIndex].content.isEmpty
            && (chats[chatIndex].messages[messageIndex].toolCalls ?? []).isEmpty
            && (chats[chatIndex].messages[messageIndex].fileChanges ?? []).isEmpty
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

    /// Немедленная синхронная запись (persistNow MA): FSM-прогон фиксирует
    /// каждый переход на диск, не дожидаясь debounce.
    func persistNow() {
        ChatPersistence.save(chats, to: fileURL)
    }
}
