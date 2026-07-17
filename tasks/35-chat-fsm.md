# 35 — FSM-пайплайн ответов в чате

## Цель
Порт полного агентного прохода `planning → execution → validation → answer` из Manager Assistant в чат: жёстко прописанная в коде машина состояний, которая гарантированно доводит сложную задачу до финального ответа. У каждого чата — переключатель «Полный проход (FSM)» / «Один запрос» (текущее поведение). Прогон переживает краш и рестарт.

## Зависимости
12 (чат), 14 (RAG), 15/21/34 (инструменты — используются внутри этапов). Закрывает пункт 8 бэклога.

## Контекст
Сейчас агентный цикл чата — плоский `ToolUseLoop` (6 итераций): модель сама решает, когда остановиться, из-за чего сложные задачи бросаются на полпути; при пустом финальном тексте выбрасывается `emptyResponse` и теряется весь ход вместе с транскриптом инструментов. Эталон: MA `Models.swift` (`TaskState`/`TaskFSM.transitions`/`TaskContext` с precondition-стражем, `PipelinePrompts` с маркерами `NEXT_STEP`/`REPLAN` и «ВЕРДИКТ:», парсеры) + MA `ChatViewModel.runStateMachine` (жёсткие гейты в коде, ретраи с принудительным выходом в answer, `persistNow()` после каждого перехода, gen-защита от гонок). In-project эталон персистентности и resume — Meeting FSM (задача 11): таблица переходов, normalize running→paused на старте, идемпотентный повтор незакоммиченной фазы.

Ключевая гарантия: цикл завершается ТОЛЬКО терминальным `answer` (или явной паузой/ошибкой со статусом) — модель не может «решить», что закончила; переходы решает код по таблице, бюджеты ретраев (execution=2, replan=2) при исчерпании форсируют answer.

## Объём работ
- [ ] `Chat/AgentFSM/AgentTaskModels.swift`: `AgentTaskState` (planning/execution/validation/answer, снисходительный decode → planning), `AgentFSM.transitions` (planning→[execution]; execution→[validation, planning]; validation→[answer, execution, planning]; answer→[] — таблица как в MA, единственный источник истины) + `allows`, `AgentRunStatus` (running/paused/failed/finished), `AgentTaskContext` (Codable, снисходительный `init(from:)`, guarded `transitioned(to:)` с precondition, счётчики executionRetries/planRetries с лимитами 2).
- [ ] `Chat/AgentFSM/AgentPrompts.swift`: системные роли этапов (планировщик/исполнитель/проверяющий/финальный ответ), структурный user-блок `[STATE]/[CURRENT]/[PLAN]/[DONE]/[QUERY]` + опциональные `[КОНТЕКСТ ДИАЛОГА]`, RAG-блок, `[ЗАМЕЧАНИЯ ПРОВЕРКИ]`, `[ПРИЧИНА ПЕРЕПЛАНИРОВАНИЯ]`; маркеры `NEXT_STEP`/`REPLAN`, «ВЕРДИКТ: ВЫПОЛНЕНО/НЕ ВЫПОЛНЕНО»; парсеры `parsePlanSteps`/`wantsNextStep`/`wantsReplan`/`parseVerdict` (неоднозначно → выполнено)/`stripMarkers`/`dialogContext`.
- [ ] `Chat/AgentFSM/AgentPhaseReducer.swift`: чистый редьюсер «контекст + текст этапа → новый контекст + сообщение для чата» (тестируемое ядро, все переходы только здесь) + `normalizeBeforePhase` — жёсткие гейты кода (validation с пустым done → execution; execution с пустым plan → planning; clamp step).
- [ ] `Chat/AgentFSM/ChatViewModel+AgentRun.swift`: оркестратор — while-цикл (один проход = один LLM-вызов), gen-защита после каждого await, инструменты этапа через общий `ToolUseLoop`, provider без tool-поддержки → фазы без инструментов, синхронный persist после каждого перехода; pause/resume/cancel; отмена → paused (не failed).
- [ ] `ChatModels.swift`: `ChatConfiguration.agentModeEnabled` (default false; ручной `encode(to:)` — не забыть), `Chat.agentContext: AgentTaskContext?`, теги `ChatMessage.agentState/agentStep/agentTotal`; всё через decodeIfPresent.
- [ ] `ChatViewModel`: `send()` ветвится по режиму; normalize на старте (running → paused); сборка инструментов + executor вынесены в общий помощник обоих путей; `deleteChat`/`cancelGeneration` гасят агентный прогон; промежуточные фазовые сообщения (state != answer) не попадают в окно истории следующих ходов.
- [ ] `ToolUse.swift`: фикс потери ответа — копить последний непустой текст ассистента между итерациями; `emptyResponse` только если и текст, и транскрипт пусты.
- [ ] UI: чип-тумблер «Полный проход (FSM)» в панели инструментов чата; бейдж этапа («Планирование», «Выполнение · шаг N/M», «Проверка», «Ответ») на сообщениях; статус-полоса активного прогона с кнопками Пауза/Продолжить/Сбросить и текстом ошибки.

## Вне объёма
Swarm-волны (параллельные подагенты), ASK_USER/уточняющие вопросы посреди прогона, router-диспетчер интеръекций (REDO/BACK/GOTO), режим «План» с подтверждением плана, инварианты/профили из MA, пайплайны-автоматизации (задача 36). Всё перечисленное — записать в BACKLOG.

## Критерии приёмки
- Тесты: таблица переходов исчерпывающе по всем парам (порт FSMTests/MeetingFSMTests); парсеры (нумерованный/маркированный/пустой план, вердикты, маркеры, stripMarkers); редьюсер (happy path, validation-fail → ретрай → форс-answer, REPLAN с бюджетом, гейты); оркестратор на скриптованном провайдере (полный прогон с тегами сообщений, resume из JSON середины прогона, ошибка → failed, отмена → paused, gen-защита); миграция старых chats.json; регрессия ToolUse (транскрипт не теряется).
- `swift build` и `swift test` зелёные.
- Ручная проверка: включить тумблер, задать составную задачу → план → пошаговое выполнение с бейджами → проверка → финальный ответ; убить приложение посреди прогона → после старта «paused», «Продолжить» доводит до ответа; с выключенным тумблером — прежний стриминг без изменений.

## Подсказки
- Extension не может добавлять хранимые свойства — `agentGen`/`agentTasks` объявлять в самом ChatViewModel.
- `CancellationError` и `URLError.cancelled` → пауза, не failed (паттерн MA).
- Пустой/мусорный план: trim, ретрай в planRetries, затем деградация в план из одного шага «выполнить задачу целиком» — гарантия терминального ответа сохраняется.
- FSM-фазы не стримятся (как текущий tool-путь) — спиннер на фазу.

## Результат

Выполнено полностью; `swift build` и `swift test` зелёные (741 тест, +37 новых).

**Что сделано** (порт TaskFSM/PipelinePrompts/runStateMachine из MA):

- `Chat/AgentFSM/AgentTaskModels.swift` — `AgentTaskState` (planning/execution/validation/answer), таблица `AgentFSM.transitions` (точно как в MA, единственный источник истины), `AgentRunStatus` (running/paused/failed/finished), `AgentTaskContext` (Codable, каждый ключ через decodeIfPresent, guarded `transitioned(to:)` с precondition, лимиты executionRetries/planRetries = 2).
- `Chat/AgentFSM/AgentPrompts.swift` — роли этапов, блок `[STATE]/[CURRENT]/[PLAN]/[DONE]/[QUERY]` + опциональные `[КОНТЕКСТ ДИАЛОГА]`/RAG/`[ЗАМЕЧАНИЯ ПРОВЕРКИ]`/`[ПРИЧИНА ПЕРЕПЛАНИРОВАНИЯ]`, маркеры NEXT_STEP/REPLAN, «ВЕРДИКТ:», парсеры (снисходительные).
- `Chat/AgentFSM/AgentPhaseReducer.swift` — **отличие от MA**: per-state switch вынесен в чистый редьюсер «контекст + текст фазы → новый контекст + сообщение» + `normalizeBeforePhase` (жёсткие гейты кода). Все переходы только здесь → исчерпывающие тесты без LLM-моков. Деградация пустого плана: ретрай в бюджете, затем план из одного шага (задача целиком).
- `Chat/AgentFSM/ChatViewModel+AgentRun.swift` — оркестратор: while-цикл (один проход = один LLM-вызов), `agentGen`-сверка после каждого await, отмена → paused (не failed), `persistNow()` после каждого перехода, pause/resume/reset. Инструменты фаз — общий `ToolUseLoop`; провайдер без function calling → фазы без инструментов (деградация, не ошибка). RAG: tool-режим отдаёт rag_search в фазы, иначе статический ретрив один раз на прогон (источники — на финальном ответе).
- ChatModels: `ChatConfiguration.agentModeEnabled` (default false, ручной encode дополнен), `Chat.agentContext`, теги `ChatMessage.agentState/agentStep/agentTotal`. `send()` ветвится по режиму; normalize (running → paused) в init; история последующих ходов фильтрует промежуточные фазы (только user + answer).
- Фикс `ToolUseLoop`: пустой финальный текст больше не выбрасывает `emptyResponse` с потерей всего хода — берётся последний непустой текст ассистента из цикла; ошибка только если пусто ВООБЩЕ (ни текста, ни вызовов). `finishGeneration` не удаляет сообщение с tool-транскриптом при пустом тексте.
- UI: тумблер «Агент» в тулбаре чата, бейджи этапов на сообщениях («Выполнение · шаг N/M», цвет по этапу), статус-полоса прогона над полем ввода (Пауза/Продолжить/Сбросить), кнопка Стоп в поле ввода для FSM-прогона = пауза.

**Тесты**: AgentFSMTests (эталонная таблица + все пары, терминальность answer), AgentTaskContextMigrationTests (минимальный JSON, неизвестные enum → дефолты, round-trip, старый Chat без новых полей, agentModeEnabled через ручной encode), AgentPromptsTests (план: нумерация/буллеты/маркеры-артефакты/фолбэк/пусто; вердикты; stripMarkers; состав buildPrompt; фильтр dialogContext), AgentReducerTests (happy path, validation-fail → ретрай → форс-answer, REPLAN с бюджетом, деградация пустого плана, гейты), AgentOrchestratorTests (полный прогон с тегами и персистом, resume после «краша» с середины, ошибка → failed → resume доводит, пауза отменой на том же шаге, gen-защита сброса, agentMode=off не затронут), регрессия ToolUseLoop (3 теста).

**Ручная проверка** (live, Ollama qwen2.5): тумблер кликается и персистится; составная задача прошла planning → 16 шагов execution → validation НЕ ВЫПОЛНЕНО → ретрай → REPLAN → новый план → validation пройдена; «Пауза» посреди прогона остановила на том же этапе; «Продолжить» довела до answer/finished; финальный ответ тегирован и сохранён. Замечание: маленькая модель строит избыточные планы (16–22 шага) — возможный тюнинг промпта планировщика («не более N шагов») оставлен на практику.

**Агентам следующих задач**:
- 36 (пайплайны): точка входа прогона — `startAgentRun`/`runAgentStateMachine`; для движка пайплайнов переиспользуй `AgentPhaseReducer`+`AgentPrompts` поверх destination-чата (оркестратор привязан к ChatViewModel — либо дай пайплайну свой тонкий оркестратор, либо вынеси общий).
- Бэклог пп. 23–26 — swarm, ASK_USER, router интеръекций, режим «План»; п. 14 — Gemini sendWithTools (в FSM Gemini работает без инструментов).
