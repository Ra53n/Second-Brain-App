// PipelineEngine.swift — прогон пайплайна поверх destination-чата (задача 36).
//
// Движок НЕ гоняет LLM сам: FSM-оркестратор задачи 35 неотделим от
// ChatViewModel (фазовые сообщения с тегами, persistNow, gen-защита), поэтому
// прогон = подготовить destination-чат (создать при отсутствии, перенести
// toolSelection пайплайна в его конфигурацию) и дождаться обычного
// runAgentToCompletion / runSingleTurnToCompletion. Сообщения этапов и итог
// появляются в этом чате как при ручном прогоне.
//
// Инварианты:
//  - overlap guard (эталон MeetingPipeline.runningIDs): второй запуск при
//    живом первом НЕ ждёт, а фиксируется записью skippedOverlap;
//  - запись running создаётся ДО вызова LLM и финализируется после (паттерн
//    MA runsRepo) — рестарт посреди прогона оставляет след для normalize;
//  - пайплайн — источник истины для СВОИХ полей конфигурации чата
//    (инструменты/базы/режим/модель); ручные правки чата между прогонами
//    перезаписываются следующим прогоном. Остальное (temperature,
//    historyWindow, ragTopK…) не трогаем.
//  - осознанное упрощение: пауза/возобновление прогона руками пользователя в
//    destination-чате фиксируется в истории как error (движок ждёт только
//    первый Task оркестратора — см. runAgentToCompletion).

import Foundation

@MainActor
final class PipelineEngine {
    private let store: PipelineStore
    private let chatViewModel: ChatViewModel

    /// Overlap guard: пайплайны с живым прогоном.
    private(set) var runningPipelineIDs: Set<UUID> = []

    init(store: PipelineStore, chatViewModel: ChatViewModel) {
        self.store = store
        self.chatViewModel = chatViewModel
    }

    /// Полный прогон пайплайна. payload — полезная нагрузка триггера
    /// ({{trigger_payload}}), scheduledFor — cron-слот (дедуп в планировщике).
    @discardableResult
    func run(_ pipeline: PipelineConfig,
             trigger: PipelineRunTrigger,
             payload: String? = nil,
             scheduledFor: Date? = nil) async -> PipelineRun {
        var run = PipelineRun(pipelineID: pipeline.id, trigger: trigger)
        run.payloadSummary = payload
        run.scheduledFor = scheduledFor

        // Overlap guard: свой Set — прогон этого же пайплайна ещё жив.
        guard !runningPipelineIDs.contains(pipeline.id) else {
            return recordSkipped(run, reason: "Предыдущий прогон ещё выполняется.")
        }

        // Destination-чат: существующий либо новый «Пайплайн: <имя>».
        let (chatIndex, createdChat) = resolveDestinationChat(for: pipeline)
        let chatID = chatViewModel.chats[chatIndex].id
        run.destinationChatID = chatID

        // Чат занят (пользовательская генерация или чужой FSM-прогон) — тоже
        // overlap: не встаём в очередь и не рвём чужую работу.
        if chatViewModel.chats[chatIndex].isLoading
            || chatViewModel.chats[chatIndex].agentContext?.status == .running {
            return recordSkipped(run, reason: "Чат назначения занят другой генерацией.")
        }

        runningPipelineIDs.insert(pipeline.id)
        defer { runningPipelineIDs.remove(pipeline.id) }

        applySelection(pipeline, toChatAt: chatIndex)
        let prompt = PipelineTemplate.render(pipeline.inputTemplate, payload: payload)

        // Снапшот сообщений ДО прогона: токены и итог считаем по новым.
        let messagesBefore = Set(chatViewModel.chats[chatIndex].messages.map(\.id))

        // running-запись — ДО вызова LLM (crash-safety).
        store.appendRun(run)

        var errorText: String?
        switch pipeline.agentMode {
        case .fsm:
            let status = await chatViewModel.runAgentToCompletion(chatIndex: chatIndex,
                                                                  userText: prompt)
            switch status {
            case .finished:
                errorText = nil
            case .failed:
                errorText = chatViewModel.chats.first { $0.id == chatID }?
                    .agentContext?.errorText
                    ?? chatViewModel.chats.first { $0.id == chatID }?.errorText
                    ?? "Прогон завершился ошибкой."
            case .paused, .running:
                errorText = "Прогон прерван (пауза/отмена)."
            }
        case .single:
            errorText = await chatViewModel.runSingleTurnToCompletion(chatIndex: chatIndex,
                                                                      userText: prompt)
        }

        // Созданный пайплайном чат сохраняет своё имя: автотайтл из первого
        // сообщения пользователя (startAgentRun/startGeneration) здесь не нужен.
        if createdChat, let index = chatViewModel.chats.firstIndex(where: { $0.id == chatID }) {
            chatViewModel.chats[index].title = "Пайплайн: \(pipeline.name)"
        }

        // Финализация: статус, токены и итоговое сообщение — по сообщениям,
        // появившимся за время прогона.
        let newMessages = (chatViewModel.chats.first { $0.id == chatID }?.messages ?? [])
            .filter { !messagesBefore.contains($0.id) }
        let tokens = Self.sumTokens(of: newMessages)
        let resultMessageID = newMessages.last { $0.role == .assistant }?.id
        store.updateRun(id: run.id) { stored in
            stored.finishedAt = Date()
            stored.status = errorText == nil ? .ok : .error
            stored.errorText = errorText
            stored.resultMessageID = resultMessageID
            stored.promptTokens = tokens.prompt
            stored.completionTokens = tokens.completion
            stored.totalTokens = tokens.total
        }
        return store.runs.first { $0.id == run.id } ?? run
    }

    // MARK: - Внутренности

    /// Индекс destination-чата; отсутствующий/удалённый → новый чат
    /// «Пайплайн: <имя>» в КОНЦЕ списка (не выдёргиваем пользователя из
    /// текущего чата), id записывается обратно в конфиг пайплайна.
    private func resolveDestinationChat(for pipeline: PipelineConfig)
        -> (index: Int, created: Bool) {
        if let destinationID = pipeline.destinationChatID,
           let index = chatViewModel.chats.firstIndex(where: { $0.id == destinationID }) {
            return (index, false)
        }
        let chat = Chat(title: "Пайплайн: \(pipeline.name)")
        chatViewModel.chats.append(chat)
        chatViewModel.persistNow()
        store.mutate(id: pipeline.id) { $0.destinationChatID = chat.id }
        store.persistNow()
        return (chatViewModel.chats.count - 1, true)
    }

    /// Перенос toolSelection пайплайна в конфигурацию destination-чата.
    /// Непустой набор баз включает RAG в tool-режиме (дефолт задачи 34).
    private func applySelection(_ pipeline: PipelineConfig, toChatAt index: Int) {
        var config = chatViewModel.chats[index].configuration
        config.projectToolsEnabled = pipeline.projectToolsEnabled
        config.enabledMCPServerIDs = pipeline.enabledMCPServerIDs
        config.enabledKnowledgeBaseIDs = pipeline.enabledKnowledgeBaseIDs
        config.ragEnabled = !pipeline.enabledKnowledgeBaseIDs.isEmpty
        if config.ragEnabled { config.ragAsTool = true }
        config.agentModeEnabled = pipeline.agentMode == .fsm
        config.providerID = pipeline.providerID
        config.model = pipeline.model
        chatViewModel.chats[index].configuration = config
    }

    /// Запись skippedOverlap: мгновенный финал, прогона не было.
    private func recordSkipped(_ run: PipelineRun, reason: String) -> PipelineRun {
        var skipped = run
        skipped.status = .skippedOverlap
        skipped.errorText = reason
        skipped.finishedAt = skipped.startedAt
        store.appendRun(skipped)
        return skipped
    }

    /// Сумма токенов по метрикам сообщений прогона. nil — ни одно сообщение
    /// не принесло usage (провайдер без статистики).
    private static func sumTokens(of messages: [ChatMessage])
        -> (prompt: Int?, completion: Int?, total: Int?) {
        let metrics = messages.compactMap(\.metrics)
        func sum(_ keyPath: KeyPath<MessageMetrics, Int?>) -> Int? {
            let values = metrics.compactMap { $0[keyPath: keyPath] }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        return (sum(\.promptTokens), sum(\.completionTokens), sum(\.totalTokens))
    }
}
