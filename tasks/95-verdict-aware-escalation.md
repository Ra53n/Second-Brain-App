# Задача 95: вердикт-осознанная композиция эскалации (каскад не ухудшает ответ)

## Тип

фича/багфикс (полная: новое персистентное поле и значение enum в `EscalationRecord`)

## Модель

Fable 5

## Цель

Каскад корректен при ЛЮБОЙ комбинации тумблеров: если ответ сильной модели по вердикту
хуже ответа дешёвой (живой случай — тюн-7B выдал `{}` с hard-fail, когда 3B ответила
валидно с UNSURE), показывается ответ дешёвой ступени, эскалация помечается
«не улучшила». Эскалация никогда не может ухудшить показанный результат.

## Зависимости

91 (эскалация), 94 (multi-stage). Выполнены.

## Допущения и corner-кейсы

Требование пользователя: «могу включать что угодно, и всё должно работать корректно» —
никакой ручной настройки для корректности.

- Ранжирование вердиктов: ok > unsure > fail. Сильная модель НЕ ХУЖЕ (равно или лучше)
  → как сейчас (`succeeded`, показан её ответ). Строго хуже → показан ответ дешёвой,
  `EscalationRecord.status = .notImproved`, отчёт сильной — в новом поле
  `strongReport` (стоимость её вызовов не должна пропасть из статистики).
- Инвариант «`report` — всегда отчёт показанного ответа» сохраняется: при
  `.notImproved` показан ответ дешёвой → `report` = её отчёт; `primaryReport` при
  этом nil (не дублируется — показанный и есть primary), отчёт сильной — в
  `strongReport`.
- Снисходительные декодеры (P2): `strongReport` — decodeIfPresent; старый билд,
  увидев `notImproved`, декодирует его в `.failed` (существующее правило «незнакомый
  статус → .failed» — деградация безопасна). Тест миграции обязателен.
- Статистика: полная стоимость `.notImproved`-сообщения = метрики показанного отчёта +
  `strongReport.metrics` (сильную ступень оплатили); новый счётчик
  `escalationNotImprovedCount` (не смешивать с failed — эскалация отработала, но не
  помогла); `escalatedCount` (succeeded) не включает notImproved.
- UI: бейдж «эскалация не улучшила» (оранжево-серый) с вердиктами обеих ступеней;
  строка в «Последнем запросе»; счётчик в GridRow «Эскалация» блока «Сессия»;
  AX-value дополняется.
- Равные вердикты → показан ответ сильной (текущее поведение сохранено).
- Отмена/ошибки второй ступени — без изменений (`failed`/`unavailable` как раньше).
- Батч, multi-stage цепочка, триггер эскалации (UNSURE|FAIL) — не меняются.

## Архитектура

- Чистое ядро: `EscalationCore.composeMessage` — ветка `.succeeded` сравнивает
  `rank(strong.verdict)` с `rank(primaryReport.verdict)`; хуже → `(primaryAnswer,
  primaryReport, EscalationRecord(.notImproved, trigger: primary.verdict,
  strongReport: strong.report, providerID/model))`. `rank` — приватная функция ядра
  (ok=2, unsure=1, fail=0).
- `EscalationStatus` + case `notImproved`; `EscalationRecord` + `strongReport:
  ConfidenceReport?` (decodeIfPresent).
- `TuningChatSessionStats`: `escalationNotImprovedCount`; полная стоимость учитывает
  `strongReport.metrics`; `escalationAddedLatency`/токены — тоже (за сильную ступень
  заплатили в обоих исходах).
- UI `FineTuneChatViews`: ветка `.notImproved` в `EscalationBadge`,
  `lastEscalationLine`, GridRow «Эскалация», AX.
- VM/пайплайн/резолвер — без изменений (композиция уже в ядре).

## Объём

- Правки: `Confidence/EscalationCore.swift`, `Confidence/TuningChatSessionStats.swift`,
  `FineTuneChatViews.swift`, `FineTune/CLAUDE.md`, тесты (`EscalationCoreTests`,
  `TuningChatSessionStatsTests`, `TuningChatViewModelTests`, `TuningChatStoreTests` —
  round-trip/миграция `strongReport` и `notImproved`).

## Вне объёма

- Настраиваемые пороги самооценки (40/70); исключение scoring из триггера; честные
  чипы вердиктов сессии по первой ступени (существующий бэклог-кандидат); батч.

## Критерии приёмки

1. Сильная модель ответила хуже дешёвой (например, hard-fail `{}` против UNSURE) →
   в чате ответ дешёвой, бейдж «эскалация не улучшила» с обоими вердиктами; report —
   отчёт дешёвой; strongReport сохранён.
2. Сильная не хуже → прежнее поведение (`succeeded`, ответ сильной).
3. Статистика: notImproved-счётчик отдельно; стоимость сильной ступени входит в
   агрегаты сессии в обоих исходах.
4. Миграция: записи эпохи ≤94 без `strongReport` декодируются; `notImproved` в старом
   билде деградирует в `.failed` (по построению снисходительного декодера — тест
   текущего декодера на незнакомый статус уже есть, дополнить round-trip).
5. `./scripts/build.sh`, `./scripts/test.sh` зелёные; ревью GO.

## Отчёт тестов

Итог `./scripts/test.sh`: **1783 теста, 0 падений, 1 пропущен** (live-harness).
- `EscalationCoreTests`: таблица succeeded-ветки composeMessage (строго хуже →
  notImproved с content/report дешёвой, strongReport сохранён, primaryReport nil;
  равные → succeeded; лучше → succeeded; недостижимый unsure/ok → notImproved — ядро
  тотально); round-trip notImproved+strongReport; миграция JSON без strongReport → nil;
  незнакомый статус → .failed (существующий тест жив).
- `TuningChatSessionStatsTests`: notImproved → свой счётчик (не escalated, не failed);
  полная стоимость = показанный report + strongReport.metrics; смесь трёх исходов.
- `TuningChatViewModelTests`: интеграционный путь — дешёвая UNSURE + сильная `{}`
  (hard-fail) → показан ответ дешёвой, `.notImproved`, strongReport != nil, errorText nil.
- `TuningChatStoreTests`: round-trip документа с notImproved; JSON без strongReport.

## Смоук UI

UI-правка — только новые ветки существующих элементов (бейдж/строки статистики/AX),
новых контролов нет — смоук-сценарий `smoke/finetune.txt` не требует новых шагов.
Живой AX-прогон `./scripts/ui.sh` недоступен (системный Accessibility, -25211 —
известный хвост среды). Приложение переустановлено и перезапущено. Ручная проверка:
эскалация с ответом сильной модели хуже дешёвого → в чате ответ дешёвой, бейдж
«эскалация не улучшила» с провайдером и обоими вердиктами, счётчик «не улучшила K»
в строке «Эскалация» блока «Сессия».

## Вердикт ревью

**GO** (reviewer, read-only). Блокирующих нет; таблица исходов composeMessage полная,
rank только в ядре, primaryReport nil при notImproved, P2-декодеры и миграции доказаны
тестами, статистика без задвоения во всех четырёх исходах, тесты 91/93/94 аддитивны.
Важное (артефакты стадий) закрыто этими секциями; мелочи закрыты: provider/model
сильной модели показан в бейдже и строке notImproved; комментарий rank уточнён.
Принято как есть: локальная переменная в тесте статистики, используемая одной ветвью.

## Результат

Каскад больше не может ухудшить показанный ответ: при `succeeded`-эскалации вердикты
обеих ступеней сравниваются (ok > unsure > fail), и если сильная модель ответила
строго хуже (живой кейс — тюн-7B выдал `{}` при валидном UNSURE-ответе 3B), в чате
остаётся ответ дешёвой ступени с бейджем «эскалация не улучшила» (провайдер + оба
вердикта). Отчёт сильной ступени сохраняется в `EscalationRecord.strongReport` —
её стоимость честно входит в агрегаты сессии; отдельный счётчик «не улучшила» в
статистике. Инвариант «report — отчёт показанного ответа» держится во всех исходах.
Это делает каскад корректным при любой комбинации тумблеров: плохая самокалибровка
слабой модели (частые UNSURE/FAIL от скоринга) теперь стоит лишь лишних вызовов,
но никогда — качества ответа.

Важно следующим агентам: сравнение вердиктов — ТОЛЬКО в `EscalationCore.composeMessage`
(rank приватен в ядре, во View только ветвление по status); `escalatedCount` — только
succeeded, notImproved — свой счётчик; старый билд декодирует notImproved в .failed.
