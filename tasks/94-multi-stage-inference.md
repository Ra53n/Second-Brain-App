# Задача 94: multi-stage inference в чате тюнинга (декомпозиция инференса)

## Тип

фича (полная: новые персистентные типы `InferenceStage`/`StageMetric` + новый sheet)

## Модель

Fable 5

## Цель

Первичный запрос чата тюнинга может идти цепочкой коротких дешёвых стадий со строгим
compact-JSON между ними (декомпозиция по полям итогового ответа: говорящие → задачи с
исполнителями → сроки → финальная сборка `{"action_items": [...]}`), чтобы поднять
точность слабой локальной модели. Стадии редактируются пользователем (sheet: имя +
промпт, добавление/удаление/порядок, сброс к шаблону), включаются тумблером per-thread;
режим и разбивка по стадиям видны на сообщении (бейдж «N стадий») и в статистике —
для честного сравнения моно/мульти.

## Зависимости

85 (чат + confidence), 86 (тумблеры), 91–93 (эскалация, мульти-модельные тюны).
Все выполнены.

## Допущения и corner-кейсы

Решения пользователя: формат между стадиями — compact JSON; итог формирует финальная
LLM-стадия; включение — тумблер + бейдж (не отдельный тред).

- Multi-stage заменяет ТОЛЬКО primary: constraint/redundancy/scoring/self-check и
  эскалация работают поверх итога без изменений; эскалация всегда монолит (сильной
  модели декомпозиция не нужна); батч (`ConfidenceBatchRunner`) не тронут.
- Redundancy повторяет только финальную стадию (повтор всей цепочки — ×N вызовов;
  меряем стабильность итоговой сборки).
- `primaryLatency` = вся цепочка; `totalCalls = stageCount + extraCalls`; разбивка —
  `ConfidenceReport.stages: [StageMetric]?`.
- Непарсибельный compact JSON промежуточной стадии — не провал запроса: в следующую
  стадию идёт trim сырого текста, `parseOk=false`, сигнал `stageParseFailures` →
  вердикт не лучше UNSURE с причиной «Стадия N: ответ не в формате JSON» (P6).
  Финальная стадия проверяется constraint'ом как раньше — двойного наказания нет.
- Режим сообщения = `report.stages != nil` — нового поля в `TuningChatMessage` нет.
- Стадии — per-document (`stages: [InferenceStage]?`, nil = дефолтный шаблон; nil vs []
  различает «не редактировал» и «редактировал»); тумблер — per-thread (`stagesEnabled`,
  зеркально `escalationEnabled`).
- Пустой эффективный список стадий при включённом тумблере → монолит без бейджа
  (редактор не даёт сохранить пустое — belt and suspenders).
- Плейсхолдеры промптов: `{{transcript}}`, `{{prev}}` (выход предыдущей, "" у первой),
  `{{stage:N}}` (1-based; вне диапазона — остаётся литералом).
- Отмена посреди цепочки → `Task.checkCancellation` между стадиями, существующие
  gen-гейты/`Task.cancel()` (P5); CancellationError не глотается.
- Миграция: старый `finetune-chat.json` → `stagesEnabled=false`, `stages=nil`; старые
  отчёты без `stages` → nil (моно). Тесты миграции обязательны (P2).
- Стадия шлётся одним user-сообщением с отрендеренным промптом, без системного промпта
  датасета (прецедент — scoring/self-check); правила задачи несёт промпт финальной
  стадии (выжимка `system_prompt.txt`).

## Архитектура

- Чистое ядро (P1), новый `Confidence/StagedInference.swift`: `InferenceStage`
  {id, name, prompt}, `StageMetric` {name, latency, promptTokens, completionTokens,
  parseOk} (оба Codable, снисходительные декодеры); `StagedInferenceCore`:
  `defaultStages()` (4 стадии), `renderPrompt(template:transcript:previousOutputs:)`,
  `compactOutput(raw:)` (первый JSON-объект через рефакторенный
  `ConfidencePrompts.firstJSONObjectString` — сделать internal), `effectiveStages(_:)`.
- `ConfidencePipeline`: новый параметр `primary: PrimaryStrategy = .monolithic`
  (`.monolithic` / `.staged([InferenceStage])`) — батч и эскалация не меняются;
  ветка `.staged` — цикл стадий с progress «Стадия i/N: имя», метриками и
  checkCancellation; primary-текст = сырой ответ финальной стадии; redundancy гоняет
  messages финальной стадии; ранний hard-fail сохраняет stages в отчёте.
- `ConfidenceVerdict`: `ConfidenceReport.stages`, `ConfidenceSignals.stageParseFailures`
  → `reduce`.
- `TuningChatStore`: `TuningChatThread.stagesEnabled`, `TuningChatDocument.stages`.
- `TuningChatViewModel`: `stagesEnabled`/`stages` + сеттеры по образцу эскалации,
  снимок `primaryStrategy` до Task в `send()`.
- `TuningChatSessionStats`: `stagedAnswered`, `stagedOK`, `monoOK`,
  `avgTotalLatencyStaged?`, `avgTotalLatencyMono?`.
- UI: чип «Стадии» + иконка-кнопка «Настроить стадии» (AX-value) в `pipelineConfigRow`;
  `StageEditorSheet` (новый `FineTuneStageEditorViews.swift`, черновик-паттерн
  `MCPServerEditorView`, каркас `FineTuneImportSheet`); бейдж «N стадий» на сообщении
  (оранжевый при `parseOk=false`); строки стадий в «Последний запрос» и «Сессия»;
  AX-value дополнить.

Полный разбор — план `/Users/kynikitin/.claude/plans/polymorphic-imagining-dewdrop.md`
(включая тексты четырёх дефолтных промптов).

## Объём

- Новые: `Sources/SecondBrain/FineTune/Confidence/StagedInference.swift`,
  `Sources/SecondBrain/FineTune/FineTuneStageEditorViews.swift`,
  `Tests/SecondBrainTests/StagedInferenceCoreTests.swift`.
- Правки: `Confidence/ConfidencePipeline.swift`, `Confidence/ConfidenceVerdict.swift`,
  `Confidence/ConfidencePrompts.swift`, `Confidence/TuningChatSessionStats.swift`,
  `TuningChatStore.swift`, `TuningChatViewModel.swift`, `FineTuneChatViews.swift`,
  `FineTune/CLAUDE.md`, `smoke/finetune.txt`; тесты (`ConfidencePipelineTests`,
  `TuningChatStoreTests`, `TuningChatViewModelTests`, `TuningChatSessionStatsTests`,
  редьюсер-тесты).

## Вне объёма

- Батч на стадиях; эскалация цепочкой; TOON/enum-форматы; разные модели на разные
  стадии; условные ветвления между стадиями.

## Критерии приёмки

1. Тумблер «Стадии» включает цепочку: ответ формируется финальной стадией, на
   сообщении бейдж «N стадий», в отчёте разбивка по стадиям (latency/токены/parseOk).
2. Редактор стадий: добавление/удаление/порядок/правка имени и промпта, сброс к
   шаблону; выбор переживает перезапуск (`finetune-chat.json`); дефолтный шаблон —
   4 стадии по полям итогового JSON.
3. Непарсибельная промежуточная стадия не роняет запрос: вердикт ≤ UNSURE с причиной,
   ответ показан.
4. Статистика: блок «Последний запрос» показывает стадии; «Сессия» — сравнение
   моно/мульти (счётчики OK, latency); confidence-проверки и эскалация работают поверх
   как раньше; батч не изменён.
5. Миграция старого `finetune-chat.json` без потерь (тест).
6. `./scripts/build.sh`, `./scripts/test.sh` зелёные; смоук дополнен; ревью GO.

## Отчёт тестов

Итог `./scripts/test.sh`: **1774 теста, 0 падений, 1 пропущен** (live-harness).

- `StagedInferenceCoreTests` (новый, 30): `renderPrompt` таблицей (все плейсхолдеры,
  `{{stage:0}}`/`{{stage:5}}` вне диапазона → литерал, повтор, кириллица);
  `compactOutput` (чистый JSON / JSON в прозе / ```-обёртка / мусор / пустая строка /
  `}` внутри строкового литерала); `effectiveStages`; `defaultStages` (ровно 4, все с
  `{{transcript}}`, финальная — `action_items` + `{{stage:1/2/3}}`); декодеры
  `InferenceStage`/`StageMetric` (`{}` → дефолты, «из будущего», round-trip,
  `parseOk` отсутствует → true); `matchesDefault` (совпадение текстов при других id →
  true; правка промпта/имени, другое число, пусто → false); `RussianPlural` таблицей.
- `ConfidencePipelineTests` (+9): монолит — `stages == nil` (регрессия); `.staged` —
  raw == сырой ответ финальной, 4 метрики, totalCalls == 4, primaryLatency > 0,
  прогресс-строки; redundancy повторяет только финальную стадию (receivedMessages);
  непарсибельная промежуточная → UNSURE + причина «Стадия …»; непарсибельная финальная
  НЕ в stageParseFailures; ранний hard-fail хранит stages; отмена посреди цепочки →
  CancellationError; `.staged([])` → монолит (guard).
- `ConfidenceVerdictReducerTests` (+6): stageParseFailures → UNSURE (worse-семантика,
  FAIL побеждает, пустой не влияет, hard-fail раньше).
- `TuningChatStoreTests` (+4): миграция документа эпохи 93 → false/nil; round-trip
  стадий с кириллицей; nil vs [] различимы; «из будущего» в объекте стадии.
- `TuningChatViewModelTests` (+7): send со стадиями → report.stages != nil; тумблер
  per-thread, стадии per-document; персист через temp-файл; пустой effectiveStages →
  монолит.
- `TuningChatSessionStatsTests` (+3): смесь моно/мульти, только моно, только мульти.

## Смоук UI

`smoke/finetune.txt` дополнен: чип «Стадии» (вкл/выкл, обратимо), кнопка «Настроить
стадии» (AX-value); открытие sheet через AX не проверяется (модальные листы ненадёжны
для System Events — задокументировано комментарием в смоуке). Живой прогон
`./scripts/ui.sh` невозможен: системное разрешение Accessibility не выдано (-25211,
известный хвост среды задач 85–93), проверено `UI elements enabled` → false.
Приложение переустановлено `install.sh` и перезапущено (pgrep подтвердил pid).
Ручная проверка (после выдачи Accessibility): чип и sheet, добавление/удаление/порядок
стадий, «Сбросить к шаблону», бейдж «N стадий» на ответе, строки стадий в статистике.

## Вердикт ревью

Круг 1: **NO-GO** — `matchesDefault` без тестов, нет артефактов стадий, `.staged([])`
не защищён, `try!` в тесте, склонение «N стадий», оговорка о порядке подстановок.
Все замечания закрыты: тесты `matchesDefault`/`RussianPlural`/пустой цепочки добавлены;
guard `.staged([])` → монолит в пайплайне; `try!` → `throws`+`try`; склонение через
`RussianPlural.form` (бейдж и AX-строка); doc-оговорка в `renderPrompt`; артефакты —
эта секция и «Отчёт тестов».

Круг 2: **GO** — все шесть замечаний проверены по коду (не по описанию), новых нет;
сборка и полный прогон (1774/0) подтверждены ревьюером самостоятельно.

## Результат

Primary-запрос чата тюнинга декомпозируется на цепочку коротких стадий со строгим
compact JSON между ними: дефолтный шаблон — говорящие → задачи с исполнителями →
сроки → финальная сборка `{"action_items": [...]}`. Стадии редактируются в sheet
(имя + промпт, добавление/удаление/порядок, сброс к шаблону; плейсхолдеры
`{{transcript}}`/`{{prev}}`/`{{stage:N}}`), включаются чипом «Стадии» per-thread.
На сообщении — бейдж «N стадий» (оранжевый при непарсибельной промежуточной),
в «Последнем запросе» — разбивка стадий по latency, в «Сессии» — сравнение моно/мульти
(OK-счётчики и latency). Confidence-проверки, эскалация и батч не изменились:
`PrimaryStrategy` с дефолтом `.monolithic`, redundancy повторяет только финальную
стадию, непарсибельная промежуточная стадия даёт вердикт не лучше UNSURE с причиной.

Важно следующим агентам:
- `report.stages != nil` — единственный признак multi-stage ответа (нового поля в
  сообщении нет); стадии per-document (`nil` = «не редактировал», редактор пишет `nil`
  при совпадении с шаблоном — `matchesDefault`), тумблер per-thread.
- Primary-текст ветки `.staged` — СЫРОЙ ответ финальной стадии (constraint должен
  видеть, что ответила модель); финальная стадия не входит в `stageParseFailures`
  (её наказывает constraint — двойного наказания нет).
- `.staged([])` защищён guard'ом → монолит; контракт «пустые стадии фильтрует
  вызывающий» держит `effectiveStages`.

Отклонения от плана: нет. Живой AX-прогон — хвост среды (Accessibility), смоук-сценарий
дописан.
