# Задача 83: редизайн раздела «Тюнинг» — понятный флоу fine-tuning

## Тип

фича

## Модель

sonnet (кодовые стадии), модель сессии (аналитика)

## Цель

Раздел «Тюнинг» после задач 81–82 перегружен и непонятен пользователю-новичку в
fine-tuning: четыре «сегмента» — кнопки тулбара без видимой подсветки активного
(единственный индикатор `.fontWeight(.bold)` не читается на иконках), detail-экраны
роутятся по-разному, датасеты — только те, что уже лежат в `finetune/`, baseline и
критерии создаются только вручную python-скриптами из терминала.

Целевой флоу (утверждён владельцем):

1. Навигация «вкладки внутри датасета»: слева только список датасетов, справа вкладки
   **Обзор | Примеры | Baseline | Критерии | Прогоны** с явной подсветкой активной.
   «Обзор» — статус пайплайна по шагам (датасет → валидация → baseline → критерии →
   обучение → сравнение), каждый шаг со статусом и кнопкой действия.
2. Импорт любого JSONL (messages-формат) кнопкой «Добавить датасет» с автосплитом
   80/20 и синтезом всех файлов, которых требует тулчейн.
3. Кнопка «Снять baseline» — запуск `baseline.py` из приложения.
4. Генерация `criteria.md` через LLM (роутинг из настроек, напр. DeepSeek) + редактор
   критериев прямо в UI.

Облачный fine-tuning клиент не нужен — тюн только локальный (mlx, `train.py` остаётся).

## Зависимости

81, 82 (весь модуль FineTune переиспользуется).

## Объём

Детальный план по фазам — `/Users/kostyanikitin/.claude/plans/ui-abstract-fiddle.md`.
Кратко:

1. **Навигация** (`FineTuneStore`, `FineTuneViews`, `FineTuneRunViews`): `FineTuneScreen`
   → `FineTuneDatasetTab` (overview/examples/baseline/criteria/runs), `selectedRunID`,
   таб-бар с подсветкой (AX-прототип — гейт Ф0), прогоны фильтруются по датасету,
   история прогонов внутри вкладки «Прогоны».
2. **Обзор** — новое чистое ядро `FineTunePipelineStatus` (P1) + `FineTuneOverviewViews`;
   `FineTuneDataset.tunedURL` в сканере.
3. **Импорт** — `FineTuneImportCore` (P1: разбор JSONL, детерминированный сплит
   SplitMix64, синтез meta), `FineTuneDatasetImporter` (I/O, атомарно, откат при ошибке),
   `FineTuneImportViews` (sheet: fileImporter, имя, превью ошибок).
4. **Baseline** — `FineTuneRunner.snapshotBaseline/cancelBaseline` (child-процесс через
   `BackgroundProcessRegistry`, вотчдог 1800 с), персистентное поле
   `baselineCountOverrides` (+миграция), взаимные guard'ы тюн↔baseline, UI с
   подтверждением перезаписи.
5. **Критерии** — `AppFunction.finetuneCriteria`, `FineTuneCriteriaPrompts` (P1),
   `FineTuneCriteriaGenerator` (фоллбэк по `resolveChatProviders`), запись `criteria.md`
   с подтверждением перезаписи; редактор «Править ↔ Сохранить» (`TextEditor`).
6. Смоук `smoke/finetune.txt` переписывается; `scripts/ui.sh` DESTRUCTIVE +=
   «Снять baseline», «Сгенерировать критерии», «Импортировать».

## Вне объёма

- Облачный fine-tuning (OpenAI/DeepSeek API-клиент тюна).
- Сборка датасета из vault в приложении (`build_dataset.py` — BACKLOG 42).
- Слепое сравнение baseline↔тюн, пересчёт метрик `criteria.md` (BACKLOG 48).
- Генерация ответов тюна кнопкой; регистрация адаптера в `FunctionRouter`.
- Редактирование примеров датасета.
- Перенос `style_checks.py`/`dictation_checks.py` в Swift.

## Допущения и corner-кейсы

- Прогоны удалённых/переименованных датасетов остаются в `finetune-runs.json`, но не
  показываются в UI (навигация по датасету) — осознанно.
- Импорт: файл >50 МБ отклоняется; <2 валидных примеров — отказ; канонический system —
  из первой валидной строки, строки с другим system отклоняются (иначе `validate.py`
  завалит датасет позже); дубль имени — ошибка без перезаписи; ошибка на середине —
  откат каталога целиком; валидные строки пишутся дословно.
- Baseline: инкрементального прогресса нет (`baseline.py` пишет всё в конце) —
  indeterminate + elapsed; обрыв процесса не оставляет полуфайлов; одновременно
  тюн + baseline запрещены (mlx-память).
- Критерии: качество LLM-выхлопа не гарантируется — редактор + подтверждение
  перезаписи; конфликт с внешней правкой файла — last-write-wins.
- Выход приложения во время baseline: процесс гасится реестром (инвариант №2).

## Архитектура

По плану: чистые ядра `FineTunePipelineStatus`, `FineTuneImportCore`,
`FineTuneCriteriaPrompts` (P1, тесты без моков); I/O — `FineTuneDatasetImporter`,
расширение actor `FineTuneRunner` (P4); персистентность — расширение `makeDocument`
в `FineTuneStore` со снисходительным декодером и тестом миграции (P2); LLM — только
через `FunctionRouter.resolveChatProviders(for: .finetuneCriteria)` (образец —
`MeetingPipeline.summarizeStep`). Запись в `finetune/` — не vault, `VaultFileOperations`
не требуется.

**Итог гейта Ф0 (проверено вживую):** кнопка в контент-области не отдаёт System Events
ни name, ни description — ни `.plain`, ни `.bordered`, ни через `.accessibilityLabel`
(в AX-дампе `AXButton | button`). Доходит только `accessibilityValue` — имя вкладки
кладётся в него (`"Обзор"`, активная — `"Обзор — выбрано"`); `ax.applescript` ищет
подпись name → value → description, поэтому смоук находит и кликает вкладки по value.
Компонент `FineTuneTabBar` (plain-кнопки, фон+тинт активной) — принят; фоллбэк на
toolbar-кнопки не понадобился. Проверка: `check Обзор` PASS, `click Примеры` OK,
`check "Примеры — выбрано"` PASS.

## Отчёт тестов

- `./scripts/build.sh` — Build complete.
- `./scripts/test.sh` — **1425 тестов, 0 падений** (было 1334 до задачи; +91 новый).
- Новые сьюты: `FineTunePipelineStatusTests` (таблицы шагов), `FineTuneImportCoreTests`
  (parse/split/sanitizeName/meta/splitSummary, 27 шт.), `FineTuneDatasetImporterTests`
  (temp-директории: полный набор файлов, дословность, дубль, откат через инжект
  FileManager, `.writeFailed` vs `.datasetExists`), `FineTuneCriteriaPromptsTests`,
  `FineTuneCriteriaGeneratorTests` (MockChatProvider, фоллбэк, ноль кандидатов);
  расширены `FineTuneRunnerTests` (argv baseline, занятый workdir, отмена),
  `FineTuneStoreTests` (миграция `baselineCountOverrides`, makeDocument 4 поля),
  `FineTuneViewModelTests` (guard тюн↔baseline, гонка отмены с поздним результатом,
  generateCriteria/saveCriteria round-trip), `FineTuneDatasetScannerTests` (tunedURL).
- Дыры: SwiftUI-вёрстка (TabBar/Overview/Import sheet/редактор) — по правилам модуля
  проверена смоуком, не юнитами; живой прогон `baseline.py` и облачная генерация
  критериев в тестах не выполняются (моки/инжект, сети в тестах ноль).
- Контракт импорта проверен вживую: датасет в формате импортёра (20 примеров,
  сплит 16/4, синтетические meta, system_prompt.txt) прошёл реальный
  `finetune/validate.py --system … --min-assistant 30` → «OK — датасет валиден», exit 0.

## Смоук UI

`./scripts/ui.sh run smoke/finetune.txt` на установленной сборке — **31 PASS / 0 FAIL,
дважды подряд** (идемпотентность). Сценарий переписан под новую навигацию: вкладки
кликаются и ассертятся по `accessibilityValue` («<имя> — выбрано»), «Проверить датасет»
жмётся вживую («OK — датасет валиден»), опасные кнопки («Запустить тюн», «Снять
baseline», «Сгенерировать критерии», «Импортировать») — только check присутствия,
добавлены в DESTRUCTIVE `scripts/ui.sh`. Маркер раздела «Тюнинг» в `ui.sh` обновлён
(«Добавить датасет» вместо убранного сегмента «Датасеты»).

## Вердикт ревью

`reviewer` (субагент, read-only): **GO**. Блокирующих нет. Важные 1–4 исправлены до
коммита: гонка повторного «Снять baseline» в окне SIGTERM→SIGKILL (guard занятого
workdir в раннере + снятие только своего хэндла), валидация имени на границе
`FineTuneDatasetImporter` (`.badName`), различение `.datasetExists` от прочих ошибок
`createDirectory` (`.writeFailed`), guard пустого датасета в `generateCriteria`.
Важное 5 — тесты отката импортёра и гонки отмены — добавлены (в тесте гонки пойман и
исправлен подвис: раннер с `fineTuneRoot: nil` не доходил до инжектированного CLI).
Мелочи: `.failed`-прогон теперь `.attention` на «Обзоре», `saveCriteria` сбрасывает
ошибку генерации, `.id(dataset.id)` на вкладке «Прогоны»; остальное — BACKLOG 53.

## Критерии приёмки

1. Активная вкладка раздела «Тюнинг» визуально подсвечена (фон/тинт), сайдбар-подсветка
   раздела штатная; смоук находит и кликает вкладки через AX.
2. Выбор датасета слева ведёт на «Обзор» с шагами пайплайна; статусы шагов соответствуют
   данным на диске (валидация/baseline/критерии/прогоны/tuned).
3. Импорт JSONL: валидный файл → новый датасет в списке, `validate.py` по нему даёт
   «OK — датасет валиден»; битые строки показаны с номерами; дубль имени — ошибка.
4. «Снять baseline» запускает `baseline.py`, процесс в реестре, отмена работает,
   результат появляется на вкладке Baseline; при идущем тюне кнопка недоступна.
5. «Сгенерировать критерии» пишет `criteria.md` через выбранного провайдера
   (с подтверждением перезаписи); редактор сохраняет правки в файл.
6. `./scripts/build.sh`, `./scripts/test.sh` зелёные; новые ядра покрыты тестами;
   тест миграции нового поля стора есть.
7. `smoke/finetune.txt` переписан и проходит `./scripts/ui.sh` дважды подряд.
8. `git grep -I --cached -e 'sk-' -e 'ghp_' -e 'AIza'` пусто.

## Результат

Сделано (все фазы плана):

1. **Навигация**: раздел «Тюнинг» — слева только датасеты, справа вкладки датасета
   `FineTuneTabBar`: Обзор | Примеры | Baseline | Критерии | Прогоны, активная явно
   подсвечена (фон + тинт). `FineTuneScreen` удалён, прогоны фильтруются по датасету,
   история — внутри вкладки «Прогоны» (`store.selectedRunID`).
2. **Обзор**: чистое ядро `FineTunePipelineStatus` — шаги датасет → валидация →
   baseline → критерии → обучение → сравнение со статусами и кнопками действий;
   `FineTuneDataset.tunedURL` в сканере.
3. **Импорт**: «Добавить датасет» → JSONL (messages) → `FineTuneImportCore` (P1:
   разбор, детерминированный сплит SplitMix64 80/20, синтез meta) +
   `FineTuneDatasetImporter` (полный набор файлов тулчейна, откат при ошибке).
4. **Baseline из UI**: «Снять baseline» → `baseline.py` child-процессом через
   `BackgroundProcessRegistry`, отмена, счётчик примеров персистится
   (`baselineCountOverrides`, миграция с тестом), взаимные guard'ы тюн↔baseline.
5. **Критерии**: `AppFunction.finetuneCriteria` → генерация `criteria.md` любым
   chat-провайдером из настроек (фоллбэк как у встреч), подтверждение перезаписи;
   редактор «Править ↔ Сохранить» прямо на вкладке.

Отклонения от плана: нет по объёму; сверх плана — фиксы важных замечаний ревью
(см. «Вердикт ревью»).

Важно следующим агентам:
- **AX-контент-кнопки**: кнопка в контент-области не отдаёт System Events ни name,
  ни description (ни plain, ни bordered, ни `.accessibilityLabel`) — доходит только
  `accessibilityValue`. Вкладки ищутся/кликаются смоуком по value; рабочие для смоука
  кнопки действий держать в toolbar.
- Baseline — наш child-процесс (в отличие от detached-тюна), см. инвариант №2 модуля.
- Импортированный датасет обязан проходить `validate.py` без правок python —
  контракт зафиксирован в `FineTune/CLAUDE.md`.
- Живой прогон «Снять baseline» и облачная генерация критериев вживую не запускались
  (долго/платно): пути покрыты юнитами с инжектированным CLI и MockChatProvider,
  кнопки и состояния — смоуком. Первый реальный запуск — на импортированном датасете,
  не на finetune/ и dictation/ владельца.

Хвосты: BACKLOG 53 (дублирование defaultRunBaseline/defaultRunValidate, диагностика
«не JSON», единый текст readSource, ContinuationBox в тестах).
