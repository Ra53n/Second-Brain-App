# 36 — Пайплайны: раздел, CRUD, cron, PR-watch

## Цель
Новый раздел «Пайплайны»: конфигурируемые АИ-автоматизации по схеме «триггер → input → агент → output». Триггеры: ручной запуск, cron-расписание, отслеживание новых PR на GitHub. Агент — движок FSM из задачи 35 либо один запрос. Результаты прогонов — сообщениями в назначенный чат + история прогонов в разделе.

## Зависимости
35 (агентный движок), 34 (базы знаний), 21 (project tools), 15 (MCP), 17 (настройки/Keychain).

## Контекст
Схема пайплайна (требование пользователя): TRIGGER (PR / schedule / event) → INPUT (заранее написанный промпт + выбранные инструменты + база знаний) → AGENT (RAG + LLM + Tools, полный FSM-проход или один запрос) → OUTPUT (сообщения в чат). Эталон автоматизаций — routines в MA (`RoutineModels.swift`, Node `scheduler.ts`): cron per-рутина, overlap guard (прогон не стартует, пока жив предыдущий), catch-up пропущенного слота, статусы прогонов ok/error/timeout/skipped_overlap. Приложение — desktop без сервера: планировщик in-app (минутный тик), при выключенном приложении триггеры не срабатывают (catch-up компенсирует).

## Объём работ
- [ ] `Pipelines/PipelineModels.swift`: `PipelineConfig` (id, name, enabled, trigger, inputTemplate — промпт с плейсхолдерами `{{trigger_payload}}`/`{{date}}`, toolSelection: project tools вкл/выкл + MCP-серверы + ID баз знаний, agentMode: fsm|single, providerID/model override опционально, destinationChatID, catchUpOnStart); `PipelineTrigger` enum с ассоциированными значениями: `.manual`, `.cron(expression:)`, `.prWatch(owner:repo:pollIntervalMin:)`; `PipelineRun` (id, pipelineID, trigger info, startedAt/finishedAt, status: running/ok/error/skippedOverlap/missed, errorText, resultMessageID, токены). Всё Codable со снисходительным `init(from:)`.
- [ ] `Pipelines/PipelineStore.swift`: паттерн ChatStore — `pipelines.json` + `pipeline-runs.json` (кап истории ~200 прогонов), атомарная запись, карантин битого файла, `persistNow()`, normalize на старте (running-прогоны → error «прерван рестартом»).
- [ ] `Pipelines/PipelineEngine.swift`: прогон конфига — рендер inputTemplate (подстановка payload триггера), сборка инструментов по toolSelection (общий помощник из 35), запуск агентного прогона (FSM-оркестратор из 35 поверх destination-чата; сообщения этапов и итог появляются в этом чате с тегами) либо одиночного запроса; запись PipelineRun; overlap guard — `Set<UUID>` бегущих пайплайнов (паттерн `MeetingPipeline.runningIDs`).
- [ ] `Pipelines/PipelineScheduler.swift`: минимальный cron-парсер 5 полей (минута час день месяц день-недели; `*`, `*/N`, списки `a,b`, диапазоны `a-b`) + `nextDate(after:)`; один минутный тик (Task.sleep-цикл, регистрация в жизненном цикле приложения); на тике — enabled-пайплайны с подошедшим слотом → engine (с overlap guard); catch-up: при старте приложения пропущенный слот (последний successful < последний должный) → один прогон, если включён флаг.
- [ ] `Pipelines/PRWatcher.swift`: поллинг `GET https://api.github.com/repos/{owner}/{repo}/pulls?state=open` с интервалом из конфига; токен из Keychain (KeyStore, новая запись `github-token`); `lastSeenPRNumbers` per pipeline в PipelineStore; новый PR → триггер прогона с payload (номер, title, автор, url, diff_url); `If-None-Match`/ETag для экономии rate limit; ошибки сети — тихий ретрай на следующем тике, бейдж ошибки в UI.
- [ ] UI `Pipelines/PipelineViews.swift`: пункт «Пайплайны» в `AppSection` (ContentView) с иконкой; список конфигов (toggle enabled, кнопка «Запустить», статус/время последнего прогона); редактор конфига (Form: имя, триггер с полями по типу, промпт, выбор инструментов/баз/чата-назначения, режим агента, провайдер/модель); история прогонов с фильтром по пайплайну и переходом в destination-чат.
- [ ] Настройки: поле GitHub-токена (Keychain, только чтение достаточно для 36) в «Инструментах»; ссылка «как выпустить токен».
- [ ] Фоновые циклы (scheduler, watcher) корректно гасятся при `applicationWillTerminate` (правило проекта).

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
