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

    /// Раннер code review (задача 37): пресет .codeReview собирает input
    /// через него (diff+доки+тесты), а не через inputTemplate. weak — владелец
    /// обоих AppModel, проставляется в wire().
    weak var reviewRunner: CodeReviewRunner?

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

        // Снапшот сообщений ДО прогона: токены и итог считаем по новым.
        let messagesBefore = Set(chatViewModel.chats[chatIndex].messages.map(\.id))

        // running-запись — ДО подготовки input и вызовов LLM (crash-safety;
        // у пресета ревью подготовка сама ходит в сеть и может звать модель).
        store.appendRun(run)

        var errorText: String?
        if pipeline.preset == .codeReview {
            errorText = await runCodeReview(pipeline: pipeline, payload: payload,
                                            chatIndex: chatIndex)
        } else {
            let prompt = PipelineTemplate.render(pipeline.inputTemplate, payload: payload)
            switch pipeline.agentMode {
            case .fsm:
                let status = await chatViewModel.runAgentToCompletion(chatIndex: chatIndex,
                                                                      userText: prompt)
                errorText = fsmErrorText(status: status, chatID: chatID)
            case .single:
                errorText = await chatViewModel.runSingleTurnToCompletion(chatIndex: chatIndex,
                                                                          userText: prompt)
            }
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

        // Автопост ревью (задача 37): строго после успешного терминала и
        // строго content итогового сообщения (по resultMessageID). Ошибка
        // автопоста НЕ портит статус прогона — ревью состоялось; текст ошибки
        // попадает в run и баннер чата, ручная кнопка остаётся fallback'ом.
        if pipeline.preset == .codeReview, pipeline.autoPostReviewComment,
           errorText == nil, let runner = reviewRunner {
            if let postError = await runner.autoPostIfConfigured(chatID: chatID,
                                                                 messageID: resultMessageID) {
                let message = "Ревью готово, но автопост в PR не удался: \(postError)"
                store.updateRun(id: run.id) { $0.errorText = message }
                if let index = chatViewModel.chats.firstIndex(where: { $0.id == chatID }) {
                    chatViewModel.chats[index].errorText = message
                }
            }
        }
        return store.runs.first { $0.id == run.id } ?? run
    }

    // MARK: - Внутренности

    /// Прогон пресета Code Review: input собирает раннер (сеть + condense),
    /// прогон — runner.runReview (FSM + маркер reviewTarget на итоге).
    private func runCodeReview(pipeline: PipelineConfig, payload: String?,
                               chatIndex: Int) async -> String? {
        guard let runner = reviewRunner else {
            return "Code review недоступен: раннер не подключён."
        }
        guard let payload else {
            return "Ручной прогон пресета Code Review без PR невозможен — он запускается триггером PR-watch. Для ревью по ссылке используйте /review в чате."
        }
        let chatID = chatViewModel.chats[chatIndex].id
        do {
            // Стартовый комментарий в PR — ДО долгой подготовки (сжатие
            // большого диффа занимает минуты): автор PR сразу видит, что
            // агент взял его в работу. Best-effort — ошибка не мешает ревью.
            if !pipeline.startCommentTemplate.isEmpty,
               let target = PRReference.firstMatch(in: payload) {
                await runner.postStartComment(target: target,
                                              template: pipeline.startCommentTemplate,
                                              payload: payload)
            }
            // Сжатие диффа — той же моделью, что поведёт FSM: applySelection
            // уже перенёс override пайплайна в конфигурацию чата.
            let condenseProvider = chatViewModel.resolveProvider(
                for: chatViewModel.chats[chatIndex])
            let prepared = try await runner.prepareInput(
                prWatchPayload: payload,
                condenseProvider: condenseProvider,
                instruction: pipeline.inputTemplate)
            let status = await runner.runReview(prepared: prepared, chatIndex: chatIndex)
            return fsmErrorText(status: status, chatID: chatID)
        } catch {
            return (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Маппинг статуса FSM-прогона в errorText записи (nil = успех).
    private func fsmErrorText(status: AgentRunStatus, chatID: UUID) -> String? {
        switch status {
        case .finished:
            return nil
        case .failed:
            return chatViewModel.chats.first { $0.id == chatID }?.agentContext?.errorText
                ?? chatViewModel.chats.first { $0.id == chatID }?.errorText
                ?? "Прогон завершился ошибкой."
        case .paused, .running:
            return "Прогон прерван (пауза/отмена)."
        }
    }

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
        // Тумблер задачи 101 — ручной режим проверки атак, у пайплайна его нет.
        // Без сброса автопрогон над чужим контентом (диффы PR, вебхуки) унаследовал
        // бы выключенную защиту из destination-чата, и никто бы этого не увидел.
        config.promptSecurityEnabled = true
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
