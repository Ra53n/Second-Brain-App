// ChatViewModel+AgentRun.swift — оркестратор FSM-прогона (задача 35).
//
// Порт runStateMachine из Manager Assistant (ChatViewModel.swift:698-1052) в
// упрощённом виде: цикл гоняет LLM по фазам, ВСЕ переходы состояний делает
// чистый AgentPhaseReducer, оркестратор отвечает за LLM-вызовы, инструменты,
// ленту сообщений, персистентность и гонки.
//
// Дисциплина гонок (порт pipelineGen MA): после КАЖДОГО await — сверка
// поколения agentGen и Task.isCancelled; отмена = пауза на том же этапе/шаге
// (не ошибка), контекст не коммитится — resume повторит ту же фазу
// (идемпотентно). После каждого закоммиченного перехода — persistNow().

import Foundation

extension ChatViewModel {
    // MARK: - Управление прогоном

    /// Тумблер «Полный проход (FSM)» текущего чата (persisted per-чат).
    var agentModeBinding: Bool {
        get { selectedChat?.configuration.agentModeEnabled ?? false }
        set {
            guard let index = chats.firstIndex(where: { $0.id == selectedChatID }) else { return }
            chats[index].configuration.agentModeEnabled = newValue
        }
    }

    /// Запуск нового прогона: свежий контекст, сообщение пользователя в ленту.
    /// displayText (задача 37) — короткая версия для ленты/тайтла, когда
    /// полный task огромен (diff ревью); nil — показывается сам task.
    func startAgentRun(chatIndex index: Int, userText text: String,
                       displayText: String? = nil) {
        let chatID = chats[index].id
        let visible = displayText ?? text
        if !chats[index].messages.contains(where: { $0.role == .user }) {
            chats[index].title = Chat.makeTitle(from: visible)
        }
        guard resolveProvider(for: chats[index]) != nil else {
            let base = LLMError.providerUnavailable(
                chats[index].configuration.providerID ?? "chat").errorDescription ?? ""
            chats[index].errorText = base
                + " Ключи облачных провайдеров — Настройки → «Провайдеры», запуск локальных моделей — Настройки → «Локальные модели»."
            return
        }
        chats[index].errorText = nil
        chats[index].messages.append(ChatMessage(role: .user, content: visible))
        var ctx = AgentTaskContext(task: text, displayText: displayText)
        ctx.status = .running
        chats[index].agentContext = ctx
        chats[index].isLoading = true
        persistNow()
        spawnAgentTask(chatID: chatID)
    }

    /// Возобновление из paused/failed: та же незакоммиченная фаза заново.
    func resumeAgentRun(chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              let status = chats[i].agentContext?.status,
              status == .paused || status == .failed else { return }
        chats[i].agentContext?.status = .running
        chats[i].agentContext?.errorText = nil
        chats[i].errorText = nil
        chats[i].isLoading = true
        persistNow()
        spawnAgentTask(chatID: chatID)
    }

    /// Пауза: отмена доедет до pauseAgentAt — статус paused, этап/шаг не тронуты.
    func pauseAgentRun(chatID: UUID) {
        agentTasks[chatID]?.cancel()
    }

    /// Сброс прогона: контекст удаляется, сообщения фаз остаются в истории.
    func resetAgentRun(chatID: UUID) {
        agentTasks[chatID]?.cancel()
        agentTasks[chatID] = nil
        agentGen[chatID] = (agentGen[chatID] ?? 0) + 1
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[i].agentContext = nil
        chats[i].isLoading = false
        persistNow()
    }

    /// Прогон FSM до терминала для движка пайплайнов (задача 36): обычный
    /// startAgentRun + ожидание его Task. Возвращает финальный статус контекста
    /// (.finished / .failed / .paused). Осознанное упрощение: если пользователь
    /// поставил паузу и потом возобновил прогон руками, движок дождался только
    /// ПЕРВОГО Task — для истории прогонов пауза не успех, хотя возобновлённый
    /// прогон доедет до ответа в чате.
    func runAgentToCompletion(chatIndex index: Int, userText text: String,
                              displayText: String? = nil) async -> AgentRunStatus {
        let chatID = chats[index].id
        startAgentRun(chatIndex: index, userText: text, displayText: displayText)
        // Провайдер недоступен → startAgentRun вышел без запуска Task.
        guard let task = agentTasks[chatID] else { return .failed }
        await task.value
        return chats.first { $0.id == chatID }?.agentContext?.status ?? .failed
    }

    private func spawnAgentTask(chatID: UUID) {
        let gen = (agentGen[chatID] ?? 0) + 1
        agentGen[chatID] = gen
        agentTasks[chatID]?.cancel()
        agentTasks[chatID] = Task { [weak self] in
            await self?.runAgentStateMachine(chatID: chatID, gen: gen)
        }
    }

    // MARK: - Главный цикл

    /// Один проход цикла = одна фаза = один запрос модели. Цикл завершается
    /// ТОЛЬКО терминальным answer (редьюсер гарантирует его достижимость
    /// бюджетами ретраев) либо паузой/ошибкой со статусом в контексте.
    private func runAgentStateMachine(chatID: UUID, gen: Int) async {
        guard let startIndex = chats.firstIndex(where: { $0.id == chatID }),
              let ctx0 = chats[startIndex].agentContext, ctx0.status == .running
        else { clearAgentTask(chatID, gen: gen); return }
        let chatSnapshot = chats[startIndex]
        let configuration = chatSnapshot.configuration

        guard let resolved = resolveProvider(for: chatSnapshot) else {
            failAgentRun(chatID, gen: gen,
                         message: LLMError.providerUnavailable(
                            configuration.providerID ?? "chat").errorDescription ?? "Провайдер недоступен")
            return
        }
        var settings = ChatSettings(model: resolved.model)
        settings.temperature = configuration.temperature

        // Контекст предыдущего диалога — снапшот на старте прогона: реплики
        // пользователя + финальные ответы, без текущей задачи (она в [QUERY]).
        let dialog: String = {
            var msgs = chatSnapshot.messages
            // Последнее user-сообщение — текущая задача (она в [QUERY], не в
            // контексте); при displayText в ленте лежит короткая версия.
            if let last = msgs.last, last.role == .user,
               last.content == ctx0.task || last.content == ctx0.displayText {
                msgs.removeLast()
            }
            return AgentPrompts.dialogContext(messages: msgs)
        }()

        // RAG (задачи 14/34): tool-провайдер получает rag_search и сам решает,
        // когда искать; иначе — статический ретрив ОДИН раз на прогон.
        let ragToolDefinition: ToolDefinition? = {
            guard configuration.ragEnabled, configuration.ragAsTool,
                  resolved.provider is ToolCapableChatProvider else { return nil }
            return ragToolBridge?.definition(configuration.enabledKnowledgeBaseIDs)
        }()
        var ragBlock = ""
        var ragSources: [RagSource] = []
        if configuration.ragEnabled, ragToolDefinition == nil {
            let retrieval = await ragProvider?(chatSnapshot, ctx0.task)
            guard agentGen[chatID] == gen else { return }
            if Task.isCancelled { pauseAgentAt(chatID, gen: gen); return }
            ragBlock = retrieval?.block ?? ""
            ragSources = retrieval?.sources ?? []
        }

        while true {
            guard agentGen[chatID] == gen, !Task.isCancelled else {
                pauseAgentAt(chatID, gen: gen)
                return
            }
            guard let i = chats.firstIndex(where: { $0.id == chatID }),
                  let current = chats[i].agentContext, current.status == .running
            else { break }

            // Жёсткая готовность этапа (гейты кода): переход-гейт коммитится
            // до фазы; nil — answer без результата проверки, продолжать нельзя.
            guard let ready = AgentPhaseReducer.normalizeBeforePhase(current) else {
                chats[i].agentContext?.status = .paused
                chats[i].errorText = "Нельзя сформировать ответ: этап «Проверка» не дал результата."
                chats[i].isLoading = false
                persistNow()
                clearAgentTask(chatID, gen: gen)
                return
            }
            if ready != current {
                chats[i].agentContext = ready
                persistNow()
            }

            // Директива файловых инструментов (задача 39): корень и режим
            // разрешений чата — модель знает, что правки могут ждать approve.
            let fileDirective: String? = {
                guard configuration.projectToolsEnabled,
                      let bridge = projectToolsBridge,
                      let root = bridge.rootURL(configuration.projectRootPath)
                else { return nil }
                return ChatPromptBuilder.fileToolsDirective(
                    mode: configuration.permissionMode, rootPath: root.path)
            }()
            let sys = AgentPrompts.systemPrompt(for: ready.state,
                                                secure: configuration.promptSecurityEnabled)
                + (ragToolDefinition != nil ? "\n\n" + ChatPromptBuilder.ragToolDirective : "")
                + (fileDirective.map { "\n\n" + $0 } ?? "")
            let user = AgentPrompts.buildPrompt(query: ready.task, ctx: ready,
                                                rag: ragBlock, dialog: dialog)

            let phaseStart = Date()
            do {
                let phase = try await runAgentPhase(
                    chatID: chatID,
                    system: sys, user: user, settings: settings, resolved: resolved,
                    configuration: configuration, ragToolDefinition: ragToolDefinition)
                guard agentGen[chatID] == gen else { return }
                if Task.isCancelled { pauseAgentAt(chatID, gen: gen); return }
                // Пустая фаза без вызовов инструментов — сбой фазы: failed,
                // «Продолжить» повторит её же (этап/шаг не потеряны).
                if phase.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   phase.transcript.isEmpty {
                    throw LLMError.emptyResponse
                }
                guard let j = chats.firstIndex(where: { $0.id == chatID }),
                      let ctx = chats[j].agentContext
                else { clearAgentTask(chatID, gen: gen); return }

                let outcome = AgentPhaseReducer.apply(ctx: ctx, phaseText: phase.text)

                var message = ChatMessage(
                    role: .assistant,
                    content: outcome.display.text.isEmpty && phase.transcript.isEmpty
                        ? "(этап не дал текста)" : outcome.display.text,
                    metrics: MessageMetrics(
                        promptTokens: phase.usage?.promptTokens,
                        completionTokens: phase.usage?.completionTokens,
                        totalTokens: phase.usage?.totalTokens,
                        duration: Date().timeIntervalSince(phaseStart),
                        providerID: resolved.providerID.rawValue,
                        providerName: resolved.displayName,
                        model: resolved.model))
                message.agentState = outcome.display.state
                message.agentStep = outcome.display.step
                message.agentTotal = outcome.display.total
                if !phase.transcript.isEmpty { message.toolCalls = phase.transcript }
                if !phase.sources.isEmpty { message.sources = phase.sources }
                // Применённые файловые операции фазы (задача 39) — diff'ы в
                // сообщение этапа: видно, ЧТО агент сделал на каждом шаге.
                if !phase.fileChanges.isEmpty { message.fileChanges = phase.fileChanges }
                // Источники статического ретрива — на финальном ответе (цитаты).
                if outcome.isTerminal, !ragSources.isEmpty {
                    message.sources = (message.sources ?? []) + ragSources
                }
                chats[j].messages.append(message)
                chats[j].agentContext = outcome.ctx
                if outcome.isTerminal {
                    chats[j].isLoading = false
                    persistNow()
                    clearAgentTask(chatID, gen: gen)
                    return
                }
                persistNow()   // шаг/переход зафиксирован на диск сразу
            } catch {
                // Отмена (CancellationError / URLError.cancelled / флаг Task) —
                // ПАУЗА на том же этапе/шаге, не ошибка.
                if error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                    || Task.isCancelled {
                    pauseAgentAt(chatID, gen: gen)
                    return
                }
                guard agentGen[chatID] == gen else { return }
                failAgentRun(chatID, gen: gen,
                             message: (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription)
                return
            }
        }
        clearAgentTask(chatID, gen: gen)
        if let i = chats.firstIndex(where: { $0.id == chatID }), agentGen[chatID] == gen {
            chats[i].isLoading = false
        }
    }

    // MARK: - Одна фаза

    /// Итог фазы: текст модели + транскрипт вызовов + источники rag_search
    /// + применённые файловые операции (задача 39).
    private struct AgentPhaseOutcome {
        var text: String
        var usage: ChatUsage?
        var transcript: [ToolCallDisplay] = []
        var sources: [RagSource] = []
        var fileChanges: [FileChangeDisplay] = []
    }

    /// Один запрос модели: с инструментами (MCP + проект + rag_search, общий
    /// ToolUseLoop) либо без (send). Провайдер без function calling при
    /// включённых инструментах НЕ ошибка — фаза идёт без инструментов
    /// (деградация как у /help), FSM работает с любым провайдером.
    private func runAgentPhase(chatID: UUID,
                               system: String, user: String,
                               settings: ChatSettings,
                               resolved: ResolvedChatProvider,
                               configuration: ChatConfiguration,
                               ragToolDefinition: ToolDefinition?) async throws -> AgentPhaseOutcome {
        // Единая сборка и маршрутизация инструментов (ChatToolAssembly):
        // источники rag_search копятся в исход фазы.
        var collectedSources: [RagSource] = []
        let tooling = await assembleTooling(
            chatID: chatID,
            configuration: configuration,
            ragToolDefinition: ragToolDefinition,
            onRagSources: { collectedSources += $0 })

        let messages: [ToolAwareMessage] = [
            ToolAwareMessage(role: .system, content: system),
            ToolAwareMessage(role: .user, content: user)
        ]

        if !tooling.tools.isEmpty,
           let toolProvider = resolved.provider as? ToolCapableChatProvider {
            // При ошибке/паузе фазы применённые операции остаются в
            // FileOpsContext чата — их вычерпает сообщение следующей фазы.
            let outcome = try await ToolUseLoop.run(
                provider: toolProvider,
                settings: settings,
                messages: messages,
                tools: tooling.tools,
                execute: tooling.execute)
            let changes = await tooling.fileOps?.drainChanges() ?? []
            return AgentPhaseOutcome(text: outcome.text, usage: outcome.usage,
                                     transcript: outcome.transcript,
                                     sources: collectedSources,
                                     fileChanges: changes)
        }

        let result = try await resolved.provider.send(
            [ChatMessageDTO(role: .system, content: system),
             ChatMessageDTO(role: .user, content: user)],
            settings: settings)
        return AgentPhaseOutcome(text: result.text, usage: result.usage)
    }

    // MARK: - Завершения

    /// Пауза на текущем этапе/шаге: контекст не коммитится, resume повторит фазу.
    private func pauseAgentAt(_ chatID: UUID, gen: Int) {
        guard agentGen[chatID] == gen else { return }
        if let i = chats.firstIndex(where: { $0.id == chatID }) {
            if chats[i].agentContext?.status == .running {
                chats[i].agentContext?.status = .paused
            }
            chats[i].isLoading = false
        }
        persistNow()
        clearAgentTask(chatID, gen: gen)
    }

    /// Ошибка фазы: состояние шага сохранено — «Продолжить» возобновит.
    private func failAgentRun(_ chatID: UUID, gen: Int, message: String) {
        guard agentGen[chatID] == gen else { return }
        if let i = chats.firstIndex(where: { $0.id == chatID }) {
            chats[i].agentContext?.status = .failed
            chats[i].agentContext?.errorText = message
            chats[i].errorText = message
            chats[i].isLoading = false
        }
        persistNow()
        clearAgentTask(chatID, gen: gen)
    }

    private func clearAgentTask(_ chatID: UUID, gen: Int) {
        guard agentGen[chatID] == gen else { return }
        agentTasks[chatID] = nil
    }
}
