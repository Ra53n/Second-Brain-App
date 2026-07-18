# 36 — Пайплайны: раздел, CRUD, cron, PR-watch

## Цель
Новый раздел «Пайплайны»: конфигурируемые АИ-автоматизации по схеме «триггер → input → агент → output». Триггеры: ручной запуск, cron-расписание, отслеживание новых PR на GitHub. Агент — движок FSM из задачи 35 либо один запрос. Результаты прогонов — сообщениями в назначенный чат + история прогонов в разделе.

## Зависимости
35 (агентный движок), 34 (базы знаний), 21 (project tools), 15 (MCP), 17 (настройки/Keychain).

## Контекст
Схема пайплайна (требование пользователя): TRIGGER (PR / schedule / event) → INPUT (заранее написанный промпт + выбранные инструменты + база знаний) → AGENT (RAG + LLM + Tools, полный FSM-проход или один запрос) → OUTPUT (сообщения в чат). Эталон автоматизаций — routines в MA (`RoutineModels.swift`, Node `scheduler.ts`): cron per-рутина, overlap guard (прогон не стартует, пока жив предыдущий), catch-up пропущенного слота, статусы прогонов ok/error/timeout/skipped_overlap. Приложение — desktop без сервера: планировщик in-app (минутный тик), при выключенном приложении триггеры не срабатывают (catch-up компенсирует).

## Объём работ
- [x] `Pipelines/PipelineModels.swift`: `PipelineConfig` (id, name, enabled, trigger, inputTemplate — промпт с плейсхолдерами `{{trigger_payload}}`/`{{date}}`, toolSelection: project tools вкл/выкл + MCP-серверы + ID баз знаний, agentMode: fsm|single, providerID/model override опционально, destinationChatID, catchUpOnStart); `PipelineTrigger` enum с ассоциированными значениями: `.manual`, `.cron(expression:)`, `.prWatch(owner:repo:pollIntervalMin:)`; `PipelineRun` (id, pipelineID, trigger info, startedAt/finishedAt, status: running/ok/error/skippedOverlap/missed, errorText, resultMessageID, токены). Всё Codable со снисходительным `init(from:)`.
- [x] `Pipelines/PipelineStore.swift`: паттерн ChatStore — `pipelines.json` + `pipeline-runs.json` (кап истории ~200 прогонов), атомарная запись, карантин битого файла, `persistNow()`, normalize на старте (running-прогоны → error «прерван рестартом»).
- [x] `Pipelines/PipelineEngine.swift`: прогон конфига — рендер inputTemplate (подстановка payload триггера), сборка инструментов по toolSelection (общий помощник из 35), запуск агентного прогона (FSM-оркестратор из 35 поверх destination-чата; сообщения этапов и итог появляются в этом чате с тегами) либо одиночного запроса; запись PipelineRun; overlap guard — `Set<UUID>` бегущих пайплайнов (паттерн `MeetingPipeline.runningIDs`).
- [x] `Pipelines/PipelineScheduler.swift`: минимальный cron-парсер 5 полей (минута час день месяц день-недели; `*`, `*/N`, списки `a,b`, диапазоны `a-b`) + `nextDate(after:)`; один минутный тик (Task.sleep-цикл, регистрация в жизненном цикле приложения); на тике — enabled-пайплайны с подошедшим слотом → engine (с overlap guard); catch-up: при старте приложения пропущенный слот (последний successful < последний должный) → один прогон, если включён флаг.
- [x] `Pipelines/PRWatcher.swift`: поллинг `GET https://api.github.com/repos/{owner}/{repo}/pulls?state=open` с интервалом из конфига; токен из Keychain (KeyStore, новая запись `github-token`); `lastSeenPRNumbers` per pipeline в PipelineStore; новый PR → триггер прогона с payload (номер, title, автор, url, diff_url); `If-None-Match`/ETag для экономии rate limit; ошибки сети — тихий ретрай на следующем тике, бейдж ошибки в UI.
- [x] UI `Pipelines/PipelineViews.swift`: пункт «Пайплайны» в `AppSection` (ContentView) с иконкой; список конфигов (toggle enabled, кнопка «Запустить», статус/время последнего прогона); редактор конфига (Form: имя, триггер с полями по типу, промпт, выбор инструментов/баз/чата-назначения, режим агента, провайдер/модель); история прогонов с фильтром по пайплайну и переходом в destination-чат.
- [x] Настройки: поле GitHub-токена (Keychain, только чтение достаточно для 36) в «Инструментах»; ссылка «как выпустить токен».
- [x] Фоновые циклы (scheduler, watcher) корректно гасятся при `applicationWillTerminate` (правило проекта).

## Вне объёма
Webhooks/push-доставка (только поллинг), выполнение при выключенном приложении (LaunchAgent — бэклог), параллельные прогоны одного пайплайна, sink'и кроме чата (файл/уведомление — бэклог), code review пресет (задача 37).

## Критерии приёмки
- Тесты: cron-парсер (валидные/невалидные выражения, `*/N`, списки, диапазоны, `nextDate` через границы суток/месяца/года); overlap guard (второй запуск при живом первом → skippedOverlap); PipelineStore (round-trip, миграция, кап истории, normalize); PRWatcher-дифф «новые PR» на фикстурах JSON (первый прогон — baseline без триггера, новый номер → триггер, ETag 304 → тишина); PipelineEngine на скриптованном провайдере (рендер шаблона, сообщения в destination-чат, PipelineRun записан).
- `swift build` и `swift test` зелёные.
- Ручная проверка: создать пайплайн с ручным триггером → «Запустить» → результат в чате и в истории; cron `*/5 * * * *` срабатывает; PR-watch на тестовом репо ловит свежий PR и триггерит прогон.

## Подсказки
- Cron-парсер писать своим минимальным кодом с тестами — зависимость ради 5 полей не нужна.
- destination-чат: если не выбран — создавать чат «Пайплайн: <имя>» автоматически при первом прогоне.
- Rate limit GitHub без токена — 60 req/h: не поллить чаще 5 минут по умолчанию, показывать remaining из заголовков в редакторе.

## Результат

Выполнено полностью; 817 тестов зелёные (+41 новый). Все компоненты — в новом модуле `Sources/SecondBrain/Pipelines/`.

Что сделано:
- **Модели** (`PipelineModels.swift`): `PipelineConfig` (toolSelection — дискретные поля, зеркалящие ChatConfiguration: projectToolsEnabled / enabledMCPServerIDs / enabledKnowledgeBaseIDs / agentMode / providerID+model), `PipelineTrigger` с ручным Codable (`{"type":"cron",…}`, незнакомый тип → .manual), `PipelineRun` со статусами running/ok/error/skippedOverlap/missed (незнакомый → .error), `PRWatchState`, `PipelineTemplate.render` ({{trigger_payload}}/{{date}}). Всё со снисходительным `init(from:)`.
- **Стор** (`PipelineStore.swift`): `pipelines.json` (документ `{pipelines, prWatchState}`) + `pipeline-runs.json` (кап 200), атомарная запись, карантин `.corrupt.json`, debounce 300 мс + `persistNow()`, normalize running → error «Прерван рестартом приложения.», каскадная чистка runs/state при удалении пайплайна.
- **Cron** (`CronExpression.swift`): свой парсер 5 полей (`*`, `*/N`, списки, диапазоны, комбинации `a-b/N`, weekday 0–7 с 7→0, vixie-OR день/день-недели), `nextDate(after:)` с покомпонентными скачками (месяц/день/час) — «невозможное» выражение обходит горизонт 4 года за сотни итераций, DST-гэп пропускается естественно.
- **Движок** (`PipelineEngine.swift`): прогон = подготовка destination-чата (создание «Пайплайн: <имя>» при отсутствии; заголовок восстанавливается после автотайтла первого сообщения) → `applySelection` (пайплайн — источник истины для СВОИХ полей конфига чата, остальное не трогается; непустые базы включают ragEnabled+ragAsTool) → рендер шаблона → running-запись ДО LLM → awaitable-хук → финализация (токены = сумма MessageMetrics новых сообщений, resultMessageID = последний assistant). Overlap guard: Set бегущих + занятость чата (isLoading/agentContext.running) → `skippedOverlap`.
- **Планировщик** (`PipelineScheduler.swift`): чистая `PipelineScheduling` (`duePipelines` с дедупом по `PipelineRun.scheduledFor`, `catchUpDecision` → none/missedOnly/runCatchUp) + минутный тик (сон до границы минуты +0.5 с). Catch-up по эталону MA: ровно один слот, missed-запись всегда, догон — только при флаге; якорь — scheduledFor/startedAt последнего прогона либо createdAt.
- **PR-watch** (`PRWatcher.swift`): чистый `PRWatchDiff.newPRs` (baseline при lastSeen==nil; закрытые PR уходят из lastSeen — переоткрытие триггерит снова), `GitHubClient` с инжектируемым транспортом (ETag/If-None-Match, Bearer-токен, x-ratelimit-remaining), минутный цикл с per-pipeline интервалом (floor 5 мин). lastSeen — персистентно в сторе; etag/remaining/lastError — in-memory (`@Published` для бейджа).
- **Awaitable-хуки в ChatViewModel** (задача 35 не менялась семантически): `runAgentToCompletion` (startAgentRun + await agentTasks[chatID].value → финальный AgentRunStatus) и `runSingleTurnToCompletion` (startGeneration + await → errorText). Пауза/resume руками пользователя во время прогона фиксируется в истории как error — осознанное упрощение (движок ждёт только первый Task).
- **Рефакторинг 35→36**: сборка инструментов вынесена в общий `Chat/ChatToolAssembly.swift` (`assembleTooling`) — дубли в `startGeneration` и `runAgentPhase` заменены, поведение бит-в-бит (старый сьют зелёный без правок ассертов).
- **UI** (`PipelineViews.swift`): `AppSection.pipelines`, список (toggle enabled, «Запустить», статус-точка палитры MA, бейдж ошибки сети), Form-редактор (сегменты триггера с полями по типу; cron-пресеты + живая валидация с показом следующего запуска; owner/repo/интервал + remaining; промпт с подсказкой плейсхолдеров; тумблеры project tools/MCP/баз; режим агента; провайдер/модель; чат назначения; catch-up), история прогонов с переходом в destination-чат (нотификация `.openPipelineChat`).
- **Настройки**: секция «GitHub (PR-watch пайплайнов)» в «Инструментах» (SecureField, Keychain-запись `github-token`, ссылка на выпуск токена); `KeyStore.envVar` санитизирует дефис (`SECONDBRAIN_GITHUB_TOKEN_KEY`).
- **Граф/lifecycle**: PipelineStore/Engine/Scheduler/PRWatcher живут в AppModel; scheduler+watcher стартуют в `wire()` и гасятся по willTerminate (это Task-циклы, BackgroundProcessRegistry не задействован).

Отклонения от плана задачи:
- **Мосты инструментов чата переехали из `ContentView.onAppear` в `AppModel.wire()`** (wireRagProvider/wireRagTool/wireMCPBridge/wireProjectTools) — иначе пайплайн, сработавший до первого открытия раздела «Чат», бежал бы без инструментов и RAG. Побочный эффект: мосты теперь готовы с первого кадра для всех потребителей.
- `lastSeenPRNumbers` хранится не «в PipelineStore per pipeline» как отдельное поле конфига, а отдельной структурой `PRWatchState` в документе pipelines.json — пересохранение формы редактора не сбрасывает baseline.
- История прогонов показана в detail выбранного пайплайна (фильтр = выбор в списке), а не отдельным глобальным экраном.

Агентам следующих задач (37 — code review pipeline):
- Прогон запускается `PipelineEngine.run(_:trigger:payload:scheduledFor:)`; payload попадает в `{{trigger_payload}}` и в `PipelineRun.payloadSummary`. Для PR-пресета достаточно собрать `PipelineConfig` с `.prWatch`-триггером и шаблоном, дальше всё работает.
- `GitHubPullRequest.payloadText` — формат payload PR (номер/title/автор/URL/diff_url); diff сам по себе НЕ скачивается — модель может забрать его инструментами (git_diff задачи 25 или MCP).
- Сборку инструментов для любых новых потребителей делать через `ChatViewModel.assembleTooling` — не дублировать.
- Тест-харнесы: `PipelineEngineTests` (MockChatProvider + mock-дескриптор), `PRWatcherTests` (скриптованный транспорт GitHubClient), фикстуры `github_pulls_*.json`.
