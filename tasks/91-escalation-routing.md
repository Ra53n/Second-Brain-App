# Задача 91: каскадная эскалация по уверенности в чате тюнинга

## Тип

фича (полная: новые персистентные поля + новый UI-блок)

## Модель

Fable 5

## Цель

Каскадный роутинг запросов в чате тюнинга: базово отвечает дешёвая локальная модель
(mlx_lm.server); если её ответ по вердикту confidence-пайплайна UNSURE или FAIL —
запрос автоматически повторяется на выбранной пользователем «сильной» модели (любой
доступный chat-провайдер из реестра), её ответ тоже проходит пайплайн. Эскалация видна
на сообщении (бейдж) и в статистике («последний запрос» и «сессия»).

## Зависимости

85 (чат + confidence-пайплайн), 86 (тумблеры пайплайна), 89 (треды по вариантам),
90 (блок «последний запрос»). Все выполнены.

## Допущения и corner-кейсы

Решения пользователя (интервью): сильная модель — пикер в UI чата тюнинга (провайдер +
модель из `ProviderRegistry`); триггер — UNSURE или FAIL; ответ сильной модели тоже
проверяется пайплайном; включение — тумблер, действует только на чат (батч не трогаем).
MLX-совместимость нужна только обучению — эскалация это обычный inference через
`ChatProvider`, годится любая chat-модель.

Corner-кейсы:
- Тумблер включён, цель не выбрана/недоступна → ответ дешёвой сохраняется, на сообщении
  запись `unavailable` с причиной; запрос НЕ падает (P6-деградация, не `errorText`).
- Ошибка сети/провайдера сильной модели → `failed` с текстом, ответ дешёвой остаётся.
- Отмена (clearChat/смена варианта/deinit) посреди эскалации → сообщение не дописывается
  (существующие `Task.cancel()` + `chatGen`-гейты, P5); `CancellationError` второй
  ступени перебрасывается, не деградирует в `failed`.
- Ответ сильной модели тоже UNSURE/FAIL → дальше не эскалируем, вердикт честно показан.
- Ошибка самой дешёвой ступени → существующий error-path, эскалация не запускается.
- Все тумблеры пайплайна выключены → редьюсер даёт UNSURE на каждом сообщении →
  эскалация каждый раз; осознанно принимаем, фиксируем в `.help` тумблера.
- Redundancy на второй ступени принудительно OFF (повторы на облаке дороги);
  constraint/scoring/self-check — как настроил пользователь.
- Миграция: старый `finetune-chat.json` → `escalationEnabled=false`,
  `escalationTarget=nil`, сообщения без `escalation`; незнакомый `EscalationStatus`
  «из будущего» → `failed`. Тест миграции обязателен (P2).
- Батч (`ConfidenceBatchRunner`, `.allEnabled`) не изменяется.

## Архитектура

Инвариант хранения: **`TuningChatMessage.report` — всегда отчёт показанного ответа.**
При успешной эскалации контент и `report` — сильной модели, отчёт дешёвой — в
`escalation.primaryReport`; при `failed`/`unavailable` — контент и `report` дешёвой,
`primaryReport = nil` (без дублей). Зафиксировать в `FineTune/CLAUDE.md`.

- Чистое ядро (P1), новый `FineTune/Confidence/EscalationCore.swift`: `EscalationTarget`
  (providerID + model, пустая model → дефолт провайдера в момент send),
  `EscalationStatus` (succeeded/failed/unavailable, снисходительный декодер → failed),
  `EscalationRecord` (status, trigger, providerID, model, failureReason, primaryReport);
  функции `shouldEscalate(enabled:verdict:)`,
  `escalationPipelineConfig(from:)` (гасит только redundancy),
  `composeMessage(primaryAnswer:primaryReport:attempt:)` со всеми ветками `Attempt`.
- Персистентность (P2), `TuningChatStore.swift`: `TuningChatMessage.escalation`,
  `TuningChatThread.escalationEnabled` (per-thread, симметрично `pipelineConfig`),
  `TuningChatDocument.escalationTarget` (per-document — доверенная сильная модель это
  свойство окружения, не варианта). `escalationEnabled` НЕ в `ConfidencePipelineConfig`
  (тот утекает в батч через `.allEnabled`).
- Резолвер, новый `FineTune/EscalationTargetResolver.swift`: `resolve(target:registry:)
  -> .resolved(ResolvedChatProvider) | .unavailable(reason:)` — единственная точка
  контакта эскалации с `ProviderRegistry`.
- Оркестрация в `TuningChatViewModel`: инжекция `escalationResolver` замыканием (образец
  `FineTuneCriteriaGenerator`), проводка в `AppModel`; проекции `escalationEnabled`
  (тредовая) / `escalationTarget` (документная) + сеттеры по образцу `setPipelineConfig`;
  в `send()` после первой ступени — второй `ConfidencePipeline` с провайдером сильной
  модели, gen-гейт после каждого await; `lastEscalation` рядом с `lastReport`.
- Статистика, `TuningChatSessionStats`: `escalatedCount`, `escalationFailedCount`,
  `escalationShare`, `escalationAddedLatency`, `escalationPromptTokens`,
  `escalationCompletionTokens`; агрегаты стоимости сессии — «полная стоимость»
  сообщения (метрики `report` + `primaryReport.metrics` у эскалированных).
- UI, `FineTuneChatViews.swift`: пятый чип «Эскалация» в `pipelineConfigRow`;
  `escalationTargetRow` (Picker по `registry.descriptors(supporting: .chat)` + TextField
  модели, образец `ModelsSettingsTab.functionRow`), виден при включённом тумблере;
  `EscalationBadge` на сообщении; строки эскалации в блоках «Последний запрос» и
  «Сессия»; AX-value дополняется. Проводка `ProviderRegistry`:
  `ContentView → FineTuneDetailView → FineTuneChatDetailView`.

Полный разбор — план `/Users/kynikitin/.claude/plans/polymorphic-imagining-dewdrop.md`.

## Объём

- Новые: `Sources/SecondBrain/FineTune/Confidence/EscalationCore.swift`,
  `Sources/SecondBrain/FineTune/EscalationTargetResolver.swift`,
  `Tests/SecondBrainTests/EscalationCoreTests.swift`,
  `Tests/SecondBrainTests/EscalationTargetResolverTests.swift`.
- Правки: `TuningChatStore.swift`, `TuningChatViewModel.swift`,
  `Confidence/TuningChatSessionStats.swift`, `FineTuneChatViews.swift`,
  `FineTuneViews.swift`, `App/ContentView.swift`, `App/AppModel.swift`,
  `FineTune/CLAUDE.md`, `smoke/finetune.txt`, тесты
  (`TuningChatStoreTests`, `TuningChatSessionStatsTests`, `TuningChatViewModelTests`).

## Вне объёма

- Батч-прогон и его отчёты (`ConfidenceBatchRunner`, confidence/*.json|md).
- Регистрация `MlxChatProvider` в `ProviderRegistry`/`FunctionRouter` (BACKLOG 48/56).
- Многоступенчатый каскад (>2 ступеней), настраиваемые пороги confidence.
- Эскалация в основном чате приложения (Chat/) — только чат тюнинга.

## Критерии приёмки

1. Тумблер «Эскалация» и пикер цели видны на вкладке «Чат», выбор переживает перезапуск
   (`finetune-chat.json`).
2. При вердикте UNSURE/FAIL первой ступени и доступной цели ответ в чате — от сильной
   модели с её отчётом; на сообщении бейдж эскалации с обоими вердиктами.
3. Цель не выбрана/недоступна или сильная модель упала → остаётся ответ дешёвой с
   пометкой и причиной; `errorText` не выставляется.
4. Блок «Последний запрос» показывает эскалацию последнего ответа; блок «Сессия» —
   счётчик/долю эскалаций, неудачи, добавленные latency и токены; агрегаты сессии
   включают стоимость обеих ступеней.
5. Старый `finetune-chat.json` мигрирует без потерь (тест); батч-прогон не изменён.
6. `./scripts/build.sh`, `./scripts/test.sh` зелёные; смоук `smoke/finetune.txt`
   дополнен; ревью GO.

## Отчёт тестов

Новые/дополненные тесты (41 кейс по задаче):
- `EscalationCoreTests` (14): таблица `shouldEscalate` 2×3; `escalationPipelineConfig`
  гасит только redundancy (`.allEnabled`, частичный конфиг, `.default` no-op);
  `composeMessage` — все 4 ветки Attempt (content/report/primaryReport/failureReason);
  снисходительные декодеры (`status` «из будущего» → `.failed`, `{}` → дефолты),
  round-trip `EscalationRecord`/`EscalationTarget`.
- `EscalationTargetResolverTests` (9): nil-цель; неизвестный провайдер; недоступный;
  без ChatProvider-реализации; пустая model → дефолт провайдера / нет дефолта;
  явная модель вне живого списка / в списке / без резолвера списка (облако).
- `TuningChatStoreTests` (+3): миграция до-91 документа (threads без escalation-полей)
  и до-89 плоского → дефолты; round-trip с заполненными полями.
- `TuningChatSessionStatsTests` (+6): счётчики succeeded/failed/unavailable, доля,
  added latency/токены; полная стоимость succeeded = обе ступени, failed/unavailable —
  без задвоения; регрессия старых кейсов — значения не изменились.
- `TuningChatViewModelTests` (+9): интеграционный путь send → UNSURE → эскалация
  (content/report сильной, primaryReport сохранён, errorText nil); `.unavailable` и
  бросающий сильный провайдер → деградация с ответом дешёвой без errorText; OK-вердикт
  и выключенный тумблер → сильный мок не вызывался; персист/восстановление
  `escalationEnabled` (per-thread) и `escalationTarget` (per-document) через temp-файл;
  `lastEscalation`; отмена (clearChat) посреди второй ступени — сообщение не дописано.

UNSURE-триггер в моках — детерминированно, без сети (warning-провал constraint-проверки).
Итог `./scripts/test.sh`: **1668 тестов, 0 падений, 1 пропущен** (live-harness).

Смоук UI: `smoke/finetune.txt` дополнен (чип «Эскалация» вкл/выкл, пикер цели
«Не выбрано», исправлен стейл `check Статистика сессии` → `Статистика — Базовая`).
Живой AX-прогон `./scripts/ui.sh` в этой среде невозможен (`-25211`, osascript без
разрешения Accessibility — известный хвост задач 85–90); приложение переустановлено
`install.sh` и перезапущено (pgrep подтвердил).

## Вердикт ревью

**GO** (reviewer, read-only). Блокирующих нет. Важное (артефакты стадий в файле задачи)
и мелочи закрыты до коммита: `EscalationTargetResolverTests` дописан в «Объём»;
`setEscalationTarget` зовёт `syncActiveThread()` (контракт `makeDocument`); тип
`escalationResolver` помечен `@MainActor` (готовность к strict concurrency); для
`.unavailable` текст в UI — «эскалация недоступна», не «не удалась». Проверено ревьюером:
инвариант «report — показанный ответ» во всех ветках; gen-гейт после каждого await второй
ступени; CancellationError перебрасывается; снисходительные декодеры и миграция; errorText
при деградациях не выставляется; батч не тронут; статистика без задвоения; AX-value у
новых контролов; секретов в дифе нет.

## Результат

Каскадный роутинг в чате тюнинга работает: дешёвая локальная модель отвечает первой;
при вердикте UNSURE/FAIL и включённом тумблере запрос повторяется на выбранной сильной
модели (любой доступный chat-провайдер реестра), её ответ проходит тот же
confidence-пайплайн (redundancy на второй ступени принудительно выключен). В UI —
пятый чип «Эскалация» + пикер цели (провайдер + модель, per-document), бейдж на
сообщении (фиолетовый «⤴ провайдер/модель» с обоими вердиктами / оранжевый
«не удалась»/«недоступна» с причиной), строки эскалации в блоках «Последний запрос» и
«Сессия» (счётчик, доля, неудачи, добавленные latency/токены; агрегаты сессии — полная
стоимость обеих ступеней).

Важно следующим агентам:
- Инвариант: `TuningChatMessage.report` — всегда отчёт ПОКАЗАННОГО ответа; отчёт
  дешёвой ступени при успешной эскалации — в `escalation.primaryReport` (зафиксировано
  в `FineTune/CLAUDE.md`).
- `escalationEnabled` — per-thread (в `TuningChatThread`), `escalationTarget` —
  per-document; `escalationEnabled` сознательно НЕ в `ConfidencePipelineConfig`
  (тот утекает в батч через `.allEnabled`).
- `EscalationTargetResolver` — единственная точка контакта эскалации с
  `ProviderRegistry`; в VM инжектируется `@MainActor`-замыканием (проводка в AppModel).
- Деградации (`.unavailable`/`.failed`) не выставляют `errorText` — причина живёт в
  `EscalationRecord.failureReason` и доходит до UI бейджем.

Отклонения от плана: нет существенных; живой AX-прогон невозможен в среде (нет
разрешения Accessibility) — смоук-сценарий дописан, прогон — хвост среды задач 85–90.
