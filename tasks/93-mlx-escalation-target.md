# Задача 93: локальная mlx-цель эскалации (тюненая модель как сильная ступень)

## Тип

фича (полная: новое персистентное поле, второй фоновый процесс — риск инварианта №2, UI)

## Модель

Fable 5

## Цель

Целью эскалации в чате тюнинга может быть локальная тюненая модель (например, тюн 7B)
через второй `mlx_lm.server` на отдельном порту — каскад «тюн-3B → тюн-7B» целиком
локальный, без рестарта основного сервера на каждую эскалацию.

## Зависимости

91 (эскалация), 92 (per-model адаптеры и `TuneSelection` — иначе «тюненой 7B» не во
что целиться при живом 3B-чате).

## Допущения и corner-кейсы

- Порт второго сервера — константа `MlxServerConfig.escalationPort = 18766`.
- Миграция `EscalationTarget` эпохи 91 (без `kind`) → `.registry` молча; незнакомый
  `kind` «из будущего» → `.registry` → резолв даст `.unavailable` (безопасная
  деградация, не краш). Старый билд, увидев `providerID: "mlx-local"`, скажет
  «провайдер недоступен» — тоже не краш.
- Нет finished-тюна выбранной базы → `.unavailable` с причиной (имя базы).
- Первая эскалация ждёт подъёма второго сервера (до ~минуты) внутри `beforeSend` —
  прогресс «Эскалация: …» уже показывается; latency-строка статистики честно включает
  это время (допущение).
- Старт тюна/baseline гасит ОБА mlx-сервера (память); обратный гвард
  (`isTuneOrBaselineActive` на входе `send()`) уже покрывает эскалацию. Два
  одновременных запроса чата исключены `isGenerating`.
- Оба сервера регистрируются в `BackgroundProcessRegistry` и гасятся в
  `applicationWillTerminate`; idle-гашение — собственный таймер каждого экземпляра
  (инвариант №2 закрыт конструкцией `MlxServerManager`).
- Батч не трогаем.

## Архитектура

- `EscalationTarget` + `kind: EscalationTargetKind` (`String`-enum `registry` |
  `localTuned`, decodeIfPresent → `.registry`). Для `.localTuned`: `model` — база тюна,
  `providerID` — сентинел `"mlx-local"`. `EscalationRecord` не меняется.
- `MlxServerManager` не правится (порт живёт в конфиге): второй экземпляр
  `mlxEscalationServerManager` в `AppModel` с тем же `pythonResolver`; замыкание
  `stopMlxServer` гасит оба.
- `EscalationTargetResolver.resolve(target:registry:localTune:)`: ветка `.localTuned`
  ДО контакта с реестром через инжектируемый строитель `localTune: (String) ->
  EscalationResolution` (тестам — мок). В AppModel строитель: `selectTunedRun` (ядро 92)
  → `MlxServerConfig(model:adapterPath:port: .escalationPort)` →
  `MlxChatProvider(port:, beforeSend: ensureRunning, afterSend: markUsed)` — паттерн
  основного чата. Сигнатура резолвера в VM не меняется (sync; async-подъём сервера
  спрятан в `beforeSend`).
- UI `escalationTargetRow`: tag-тип пикера → enum `EscalationPickerChoice`
  (`.none` / `.registry(ProviderID)` / `.localTuned(model)`); секция «Локально (mlx)»
  с пунктами «Тюн <база> (локально)» из `viewModel.availableTunedModels` (ядро 92,
  runs-замыкание — реестр/стор во View не тянутся). TextField модели для `.localTuned`
  скрыт. AX-value дополняется. Бейдж и статистика работают без правок.

## Объём

- Правки: `Confidence/EscalationCore.swift` (kind), `EscalationTargetResolver.swift`,
  `TuningChatViewModel.swift` (availableTunedModels), `FineTuneChatViews.swift`,
  `App/AppModel.swift` (второй менеджер, stopMlxServer×2, строитель localTune),
  `MlxServerManager.swift` (константа порта), `FineTune/CLAUDE.md`,
  `smoke/finetune.txt`, тесты (`EscalationCoreTests`, `EscalationTargetResolverTests`,
  `TuningChatViewModelTests`).

## Вне объёма

- Профили каскада; эскалация в основном чате приложения; батч; регистрация mlx в
  `ProviderRegistry` (BACKLOG 48).

## Критерии приёмки

1. В пикере цели эскалации есть пункт «Тюн <база> (локально)»; выбор персистится и
   переживает перезапуск; файлы эпохи 91 мигрируют молча (тест).
2. Эскалация на локальную цель поднимает второй mlx-сервер на 18766, не трогая
   основной; ответ второй ступени проходит confidence-пайплайн; бейдж и статистика
   отражают `mlx-local/<база>`.
3. Нет тюна выбранной базы → `.unavailable` с причиной; ответ дешёвой сохранён.
4. Старт тюна/baseline гасит оба сервера; оба зарегистрированы в
   `BackgroundProcessRegistry` (инвариант №2).
5. `./scripts/build.sh`, `./scripts/test.sh` зелёные; смоук дополнен; ревью GO.

## Отчёт тестов

Новые (+16 к задаче; итог `./scripts/test.sh`: **1715 тестов, 0 падений, 1 пропущен**):
- `EscalationCoreTests` (+6): `EscalationTarget` эпохи 91 (JSON без `kind`) → `.registry`;
  незнакомый `kind` «из будущего» → `.registry` (и в отдельном enum, и внутри цельного
  JSON); round-trip `.localTuned` (kind сохраняется, providerID `mlx-local`).
- `EscalationTargetResolverTests` (+4): `.localTuned` зовёт строитель с `target.model`,
  пустой реестр не мешает; `.unavailable` строителя прокидывается; дефолтный строитель
  → `.unavailable`; `.registry` строитель не зовёт (счётчик = 0).
- `TuningChatViewModelTests` (+4): интеграционный путь UNSURE → эскалация на локальную
  цель (мок сильного, providerID `mlx-local`) → `.succeeded`; `.unavailable` → ответ
  дешёвой с причиной; `availableTunedModels` пуст без прогонов / distinct-базы только
  finished этого workdir.
- `TuningChatStoreTests` (+2): round-trip документа с `kind == .localTuned` через
  персистентность; `escalationTarget` без `kind` мигрирует на `.registry`.

Строитель `localTune` в AppModel покрыт только на моках — вынос в чистое ядро с
таблицей случаев → BACKLOG 58 (допущено ревью).

Смоук: `smoke/finetune.txt` дополнен; секция «Локально (mlx)» в рабочей копии не
рендерится (нет finished-прогонов — `finetune-runs.json` пуст), что честно
задокументировано в смоуке. Живой AX-прогон недоступен (системный тумблер
Accessibility выключен, -25211 — известный хвост среды). Приложение переустановлено
и перезапущено (pgrep подтвердил pid).

## Вердикт ревью

**GO** (reviewer, read-only). Блокирующих нет. Инвариант №2 закрыт конструкцией
(общий `BackgroundProcessRegistry.shared`, чужой сервер на 18766 не адоптируется,
idle-таймер у каждого экземпляра), `stopMlxServer` гасит оба. Важные закрыты:
артефакты стадий добавлены; вынос строителя в чистое ядро → BACKLOG 58; пикер не
исключает базу текущего чата → BACKLOG 59. Мелочи закрыты в коде: мёртвый lookup
workdir заменён литералом с комментарием; подпись «Тюн … (локально)» сведена в одну
точку `TuneSelection.localTunedDisplayName`; причина при выгруженном сторе больше
не врёт («чат тюнинга выгружен»). Принято как есть: Picker с исчезнувшей базой
показывает пустое значение (деградация безопасна — резолв даст `.unavailable`).

## Результат

Цель эскалации может быть локальной тюненой моделью: пункт «Тюн <база> (локально)» в
пикере (появляется при наличии finished-прогонов), выбор персистится
(`EscalationTarget.kind == .localTuned`, миграция файлов ≤92 → `.registry` молча).
Эскалация поднимает второй `mlx_lm.server` на порту 18766 (`ensureRunning` в
`beforeSend` провайдера), не трогая основной; ответ второй ступени проходит тот же
confidence-пайплайн; статистика/бейджи показывают `mlx-local/<база>`. Старт
тюна/baseline гасит оба сервера; оба в реестре процессов.

Важно следующим агентам: строитель `localTune` живёт в AppModel (BACKLOG 58 — вынести
решение в чистое ядро); сентинел `mlx-local` не является провайдером реестра — резолв
`.localTuned` идёт до контакта с `ProviderRegistry`.

## Follow-up (после живого прогона тюна 3B, 2026-08-01)

Живой прогон вскрыл: легаси-тюн 7B (сделан до истории прогонов, записи в сторе нет)
не попадал в пикер эскалации никогда, а после первой finished-записи 3B осиротел и в
чате — старое правило `legacyAdapterFallback` требовало «ни одной finished-записи
workdir вообще». Исправлено: отсутствие проверяется по finished-записям именно этой
базы (подмена базы по-прежнему исключена условием «только 7B-дефолт»);
`availableTunedModels` и строитель `localTune` получили легаси-ветку, зеркальную
`.tuned` в чате. Тесты: правило (finished другой базы → true, той же → false),
позитивная ветка пикера (легаси-файл есть → 7B в списке; 3B-прогон не вытесняет).
Ревью follow-up: NO-GO (нет тестов позитивной ветки, стейл CLAUDE.md) → правки → GO.
Решающая логика «run vs legacy» теперь в трёх местах — зафиксировано в BACKLOG 58.
