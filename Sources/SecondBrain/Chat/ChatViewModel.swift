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

    /// Заготовка задачи 14: (чат, текст вопроса) → блок [RAG_CONTEXT] или nil.
    var ragContextProvider: ((Chat, String) async -> String?)?

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

    var canSend: Bool {
        guard let chat = selectedChat else { return false }
        return !chat.isLoading
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Отправка со стримингом

    func send() {
        guard let index = selectedIndex else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chats[index].isLoading else { return }
        let chatID = chats[index].id

        // Автоназвание — из первого сообщения пользователя.
        if !chats[index].messages.contains(where: { $0.role == .user }) {
            chats[index].title = Chat.makeTitle(from: text)
        }
        chats[index].errorText = nil
        chats[index].messages.append(ChatMessage(role: .user, content: text))
        input = ""

        guard let resolved = resolveProvider(for: chats[index]) else {
            chats[index].errorText = LLMError.providerUnavailable(
                chats[index].configuration.providerID ?? "chat").errorDescription
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
                // Точка расширения задачи 14: retrieval перед запросом.
                let ragContext = await self.ragContextProvider?(chatSnapshot, text)
                let messages = ChatPromptBuilder.requestMessages(
                    history: history,
                    historyWindow: configuration.historyWindow,
                    ragContext: ragContext)
                var settings = ChatSettings(model: resolved.model)
                settings.temperature = configuration.temperature

                for try await chunk in resolved.provider.stream(messages, settings: settings) {
                    self.appendToMessage(chatID: chatID, messageID: placeholderID, chunk: chunk)
                }
                self.finishGeneration(chatID: chatID, messageID: placeholderID,
                                      duration: Date().timeIntervalSince(start), error: nil)
            } catch is CancellationError {
                self.finishGeneration(chatID: chatID, messageID: placeholderID,
                                      duration: Date().timeIntervalSince(start), error: nil)
            } catch {
                self.finishGeneration(chatID: chatID, messageID: placeholderID,
                                      duration: Date().timeIntervalSince(start), error: error)
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
            let model = chat.configuration.model
                ?? registry.descriptor(for: providerID)?.defaultModel
            if let model {
                return ResolvedChatProvider(provider: provider, model: model)
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

    private func finishGeneration(chatID: UUID, messageID: UUID,
                                  duration: TimeInterval, error: Error?) {
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
            chats[chatIndex].messages[messageIndex].metrics = MessageMetrics(duration: duration)
        }
        // Немедленная запись финального состояния (debounce мог не успеть).
        ChatPersistence.save(chats, to: fileURL)
    }
}
