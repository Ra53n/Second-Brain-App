# Задача 92: мульти-модельные тюны датасета (адаптеры per-model, база чата из прогона)

## Тип

фича (полная: новые персистентные поля, миграция ключей тредов, UI)

## Модель

Fable 5

## Цель

Датасет может иметь несколько тюнов на разных базовых моделях одновременно (3B и 7B):
адаптеры не перезаписывают друг друга, чат тюнинга поднимает пару «база из записи
прогона + её адаптер» вместо захардкоженной 7B (закрывает BACKLOG 56), базовая модель
чата выбирается пикером. Подготовка к каскаду «тюн-3B → тюн-7B» (задача 93).

## Зависимости

91 (эскалация в чате). Выполнена.

## Допущения и corner-кейсы

Решения пользователя: малая база — `mlx-community/Qwen2.5-3B-Instruct-4bit`; тюн 7B
сохраняется; переключение конфигураций ручное (пикеры, без профилей).

- Существующий адаптер 7B в `<workdir>/adapters` НЕ переносится: разрешение пути
  data-driven через `FineTuneRun.adapterPath` (уже персистится per-run); новые прогоны
  пишут в `adapters/<slug-модели>/`. Легаси-fallback (легаси-путь + 7B) — только при
  полном отсутствии finished-записей нужной базы, иначе тихо подсунули бы 7B-адаптер
  под 3B-базу (крах загрузки весов).
- База baseline-варианта чата = выбранная база (сравнение baseline↔тюн на одной базе);
  7B-baseline доступен тем же пикером.
- Ключ треда чата становится `"<variant>|<model>"` — статистика per (variant, base)
  автоматически раздельная. Миграция: легаси-ключи `baseline`/`tuned` → `…|<7B>`,
  история задач 89–91 цела; `{}` остаётся пустым.
- Смена базы чата = рестарт mlx-сервера (загрузка до минуты) — как при baseline↔тюн;
  отразить в `.help`.
- `run.json`/`train.log` — синглтоны на workdir: прогон 3B перетирает их у 7B. Чат
  резолвится по `FineTuneStore` (история прогонов), не по run.json. Гвард: «Взять
  лучший» (installBest) доступен только прогону, совпадающему с текущим run.json —
  иначе val-кривая чужого прогона.
- Батч-прогон НЕ трогаем: остаётся на легаси-пути адаптера (несовместимость с
  мульти-тюнами — в BACKLOG).
- `train.py` без `--adapter-dir` ведёт себя ровно как раньше (терминальный сценарий и
  README не ломаются).

## Архитектура

- `finetune/train.py`: глобальный флаг `--adapter-dir` (дефолт `"adapters"`), действует
  на `start`, `best --install`, `adapter_path` в run.json; argv для `mlx_lm.lora`
  по-прежнему собирает CLI (инвариант модуля №1).
- Чистое ядро (P1), новый `Sources/SecondBrain/FineTune/TuneSelection.swift`:
  `adapterDirName(model:)` (slug, санитизация `/`), `selectTunedRun(runs:workdir:baseModel:)`
  (последний `.finished` прогон базы), `chatBaseModels(runs:defaults:)` (для пикера:
  дефолты 3B+7B + distinct-модели finished-прогонов), правило легаси-fallback.
  Проверка наличия `adapters.safetensors` — I/O, остаётся в VM.
- `FineTuneRunner`: `start` добавляет `--adapter-dir adapters/<slug>`;
  `installBest(workdir:adapterDir:)` — флаг выводится из `run.adapterPath`, не
  пересчитывается из модели; результат CLI проверяется по status.
- `TuningChatStore`: `TuningChatDocument.chatBaseModel: String?` (decodeIfPresent,
  nil → 7B); миграция легаси-ключей тредов в `init(from:)`.
- `TuningChatViewModel`: инжекция `runs: () -> [FineTuneRun]` (из `fineTuneStore`, по
  образцу `dataset:`); `.tuned` → `MlxServerConfig(model: run.model, adapterPath:
  dir(run))` от `selectTunedRun`, нет прогона/файла → `adapterMissing` с именем базы;
  `.baseline` → `MlxServerConfig(model: chatBaseModel)`; смена базы — зеркально
  `modelVariant.didSet` (отмена генерации, saveThread старого ключа, загрузка нового);
  `availableBaseModels` для пикера.
- UI: пикер базы чата в `FineTuneChatViews` (рядом с переключателем варианта);
  пресеты модели прогона (3B/7B) в `FineTuneRunViews` (там уже есть TextField модели);
  гвард installBest в `FineTuneRunViews`/VM.
- Проводка в `AppModel` (runs-замыкание).

## Объём

- Новые: `Sources/SecondBrain/FineTune/TuneSelection.swift`,
  `Tests/SecondBrainTests/TuneSelectionTests.swift`.
- Правки: `finetune/train.py`, `FineTuneRunner.swift`, `TuningChatStore.swift`,
  `TuningChatViewModel.swift`, `FineTuneChatViews.swift`, `FineTuneRunViews.swift`,
  `FineTuneViewModel.swift` (гвард installBest, пресеты), `App/AppModel.swift`,
  `FineTune/CLAUDE.md`, `smoke/finetune.txt`, тесты (`TuningChatStoreTests`,
  `TuningChatViewModelTests`, `FineTuneRunnerTests`).

## Вне объёма

- Сам прогон тюна 3B (ручной шаг после 92/93).
- mlx-цель эскалации и второй сервер (задача 93).
- Батч-прогон на per-model адаптерах (BACKLOG).
- Профили каскада.

## Критерии приёмки

1. Прогон с базой 3B пишет адаптер в `adapters/Qwen2.5-3B-Instruct-4bit/`, адаптер 7B
   в `adapters/` не тронут; `train.py` без `--adapter-dir` работает как раньше.
2. Чат `.tuned` поднимает пару (база прогона, его адаптер) из `FineTuneStore`; при
   отсутствии тюна выбранной базы — ошибка с именем базы; легаси-fallback только при
   полном отсутствии записей.
3. Пикер базы чата переключает треды `variant|model`; история и статистика эпохи ≤91
   мигрируют в `…|7B` без потерь (тест).
4. «Взять лучший» недоступен для прогона, не совпадающего с текущим run.json.
5. `./scripts/build.sh`, `./scripts/test.sh` зелёные; смоук дополнен; ревью GO.

## Отчёт тестов

Новые/обновлённые (итог `./scripts/test.sh`: **1699 тестов, 0 падений, 1 пропущен**):
- `TuneSelectionTests` (новый, 16): `adapterDirName`/`adapterDir` таблицей, включая
  вырожденные входы (пусто, «/», «.», «..», «../..», « / » → `default` — фикс
  path-traversal, найденного тестером); `selectTunedRun` (чужой workdir/база,
  несколько finished → последний по дате, не-finished статусы); `chatBaseModels`
  (дедуп, стабильный порядок); `legacyAdapterFallback` (только «нет finished вообще»
  И база 7B).
- `TuningChatStoreTests` (18): ключи `variant|model`; миграция литерального JSON
  эпохи 91 (escalation-поля целы, ключи → `…|7B`, `chatBaseModel` nil); round-trip.
- `TuningChatViewModelTests` (+6): смена `chatBaseModel` (раздельная история,
  P5-отмена), `.tuned` с finished 3B-прогоном → конфиг (3B, adapterPath прогона),
  `.tuned` 3B без прогонов → `tunedRunMissing` с именем базы, `availableBaseModels`;
  легаси-fallback покрыт существующими тестами (фикстуры с `adapters/`).
- `FineTuneRunnerTests` (+4): `--adapter-dir adapters/<slug>` в argv, `installBest`
  передаёт adapterDir, `currentCLIRun` без проверки живости pid.
- `FineTuneViewModelTests` (+2): гвард installBest — без refreshCurrentRun CLI не
  зовётся; чужой run.json блокирует.

Смоук: `smoke/finetune.txt` дополнен (пикер «База», «Взять лучший чекпоинт»);
живой AX-прогон `./scripts/ui.sh` невозможен — системный тумблер Accessibility
выключен на уровне среды (-25211, проверено `UI elements enabled` → false), известный
хвост задач 85–91. Приложение переустановлено `install.sh` и перезапущено (pgrep).
Пресеты 3B/7B и disabled-состояние гварда — вне досягаемости AX-смоука
(кнопки в Form не отдают AX, `AXEnabled` скрипт не читает) — ручная проверка.

## Вердикт ревью

**GO** (reviewer, read-only). Блокирующих нет. Важные закрыты до коммита: артефакты
стадий добавлены в файл задачи; BACKLOG 56 переформулирован на остаток (батч на
легаси-7B, чатная часть закрыта → 92). Мелочи закрыты: дублированная сборка
легаси-пути в VM (`deletingLastPathComponent`), guard пустого `run.adapterPath` в
installBest. Принято без правок: недетерминированный победитель при недостижимой
коллизии ключей миграции; текст `adapterMissing` без имени базы (рядом есть
`tunedRunMissing(model:)`).

## Результат

Датасет держит несколько тюнов одновременно: новые прогоны пишут адаптер в
`adapters/<slug-модели>/` (`train.py --adapter-dir`, без флага — прежнее поведение),
легаси `adapters/` не переносится и резолвится data-driven через
`FineTuneRun.adapterPath`. Чат тюнинга поднимает пару «база прогона + его адаптер» из
`FineTuneStore` (BACKLOG 56 — чатная часть закрыта), база выбирается пикером, треды и
статистика раздельны по ключу `variant|model` с миграцией истории ≤91 в `…|7B`.
Легаси-fallback — только при полном отсутствии finished-записей и базе 7B. «Взять
лучший» защищён сверкой с текущим run.json (val-кривая чужого прогона исключена).
Пресеты 3B/7B в форме прогона.

Важно следующим агентам: `TuneSelection` — единственная точка правил выбора
тюна/слага/фолбэка (P1, менять только с таблицей тестов); батч остаётся на
легаси-пути (BACKLOG 56-остаток); в форме Run кнопки внутри Form не отдают AX —
пресеты проверяются руками.
