# Модуль FineTune — правила

Раздел «Тюнинг»: просмотр датасетов LoRA-тюна и запуск/наблюдение прогона. Сам тюн —
внешний CLI-тулчейн `finetune/` (вне SPM-таргета, в репозитории); модуль его только
вызывает и читает.

## Что здесь живёт

- `FineTuneModels` — доменные типы: `FineTuneDataset`, `FineTuneExample`/`Meta`,
  `FineTuneProgressPoint`, `FineTuneHyperparameters`, `FineTuneRun`, `FineTuneCLIRun`
  (декодер `run.json`), `FineTuneError`.
- `FineTuneLogParser` / `FineTuneCheckpointPicker` / `FineTuneJSONL` / `FineTuneRunTick` —
  чистое ядро (P1): строка лога → точка прогресса, точки val loss → лучший чекпоинт,
  строка jsonl → тело/мета, факты одного тика (новый текст лога, жив ли pid, есть ли
  адаптер) → обновлённый прогон и хвост лога.
- `FineTuneDatasetScanner` — сканирование каталогов-датасетов (I/O).
- `FineTuneEnvironment` — поиск python с mlx-lm (кандидаты чистые, `probe` — дорогой I/O
  с таймаутом и SIGTERM→SIGKILL выжившему).
- `FineTunePidProcess` — `ManagedProcess` поверх голого pid.
- `FineTuneRunner` — actor, запускает подкоманды CLI (таймаут на каждую), регистрирует
  процесс обучения (`adoptIntoRegistry`) или снимает с отслеживания (`markProcessFinished`).
- `FineTuneLogTail` — дочитывание `train.log` от сохранённого смещения.
- `FineTuneQuitGuard` — мост к `AppDelegate` на выходе: `activeRun(in:)` решает, какой
  прогон показать в диалоге (P1).
- `FineTuneValidationParser` — чистое ядро (P1): вывод `validate.py` (заметки в stdout,
  ошибки в stderr, код 0/1) → результат проверки со списком ошибок «файл:строка — текст».
- `FineTuneOutputsReader` — чистое ядро (P1): снятые ответы модели. Два формата
  `outputs.json` (новый объект с метаданными прогона и старый плоский список) и два
  поколения `.md` (`## Вход` в свежих, `## Задание` в закоммиченных).
- `FineTuneOutputsIO` — чтение каталога снимка с диска (I/O, отдельно от чистого ядра).
- `FineTuneStore` (P2) / `FineTuneViewModel` — персистентность прогонов, результатов
  валидации, порогов `--min-assistant` и счётчиков baseline, плюс состояние экрана.
- `FineTuneTabBar` — вкладки датасета (задача 83): Обзор | Примеры | Baseline |
  Критерии | Прогоны. Кнопки контент-области НЕ отдают AX ни name, ни description
  (ни plain, ни bordered, ни `.accessibilityLabel`) — до System Events доходит только
  `accessibilityValue`, поэтому имя вкладки лежит в нём (активная — `"<имя> — выбрано"`).
- `FineTunePipelineStatus` — чистое ядро (P1): входные факты датасета → шаги пайплайна
  со статусами и действиями для вкладки «Обзор».
- `FineTuneImportCore` (P1) / `FineTuneDatasetImporter` (I/O) — импорт внешнего JSONL:
  разбор, детерминированный сплит (SplitMix64), синтез meta; запись полного набора
  файлов, которых требует python-тулчейн.
- `FineTuneCriteriaPrompts` (P1) / `FineTuneCriteriaGenerator` — генерация `criteria.md`
  по примерам датасета через `FunctionRouter` (`AppFunction.finetuneCriteria`), фоллбэк
  по кандидатам как в `MeetingPipeline.summarizeStep`.

## Инварианты

1. **Контракт с CLI — файлы, не stdout.** `train.py` не печатает JSON ни в одной
   подкоманде; машиночитаемы только `<workdir>/runs/run.json` и `train.log`. Новую логику
   мимо этих двух файлов не добавлять — argv для `mlx_lm.lora` собирает CLI, в Swift не
   дублируется.
2. **Обучение — не наш child-процесс.** `train.py start` спавнит через
   `Popen(start_new_session=True)` и сразу выходит; у нас только pid из `run.json`, и он
   лидер сессии (`killpg` гасит и воркеров). Поэтому в `BackgroundProcessRegistry`
   регистрируется `FineTunePidProcess`, а не `Process`. **Baseline — наоборот, наш
   child-процесс**: `baseline.py` живёт до конца генерации, регистрируется как обычный
   `Process` (после `run()`) и гасится при выходе; одновременный тюн и baseline
   запрещены взаимными guard'ами (mlx-память).
3. **pid ≤ 1 не превращается в сигнал.** `FineTunePidProcess.init?` отвергает такой pid:
   `killpg(0, …)` бьёт по группе процессов самого приложения, `killpg(1, …)` — по launchd.
   Битый или недописанный `run.json` (декодер даёт -1 при отсутствии поля) обязан приводить
   к ошибке старта, а не к сигналу. Тот же guard — в `FineTuneStore.normalize()`
   (`kill(0, 0)` отвечает 0, иначе pid 0 выглядел бы вечно живым).
4. **«Оставить работать» — не баг, а осознанный путь.** `detachFromQuit()` переводит
   `isRunning` в `false` и оба сигнала — в no-op; `terminateAll()` пропускает прогон без
   трёхсекундного ожидания. При следующем старте раздел подхватывает его заново по
   `run.json` (`FineTuneRunner.adopt`), не по внутреннему состоянию.
5. **Лог перечитывается таймером, а не подпиской на файл.** mlx-lm дописывает `train.log`
   раз в ~11 с; `DispatchSource` только усложнил бы. `FineTuneLogTail` не заводит таймер
   сам — секундный тик и его вызов `readNew()` — забота `FineTuneViewModel`.
6. **`run.json` дрейфует.** Формат менялся (`val_batches` на диске 4 против дефолта -1,
   `learning_rate` — строка). Каждое поле `FineTuneCLIRun`/`FineTuneRun` — через
   `decodeIfPresent` + дефолт, без исключений.
7. **`started_at` — эпоха с 1970, не с 2001.** Python пишет `time.time()`; дефолтный
   Codable-декодер `Date` ждёт `timeIntervalSinceReferenceDate` (с 2001) — конверсия в
   `FineTuneCLIRun.init(from:)` ручная, иначе даты стартов будут врать на ~31 год.
8. **Чекпоинт по val loss, не по последней итерации.** На малых датасетах train loss
   продолжает падать после начала переобучения. `FineTuneCheckpointPicker.best` — минимум
   val loss, при ничьей — более ранняя итерация.
9. **Подхват (`adopt`) регистрирует в реестре только «свой» прогон.** `FineTuneViewModel`
   решает через `FineTuneStore` (совпадение workdir+pid **и status == .running** с уже
   известной записью — иначе переиспользованный системой pid воскресил бы завершённую
   запись и стёр её `points`), «свой» это или запущенный вне приложения (терминал) —
   только тогда зовёт `FineTuneRunner.adoptIntoRegistry`. Чужой прогон помечается
   `isAdoptedExternally` и виден в UI, но в `BackgroundProcessRegistry` не попадает,
   на выходе не гасится и **в диалог выхода не попадает вовсе** (`FineTuneQuitGuard.
   activeRun(in:)`) — кнопка «Остановить» там была бы обманом.
10. **Раннер не читает MainActor-состояние из своего актора.** Корень `finetune/` в
    `FineTuneRunner` — снимок `URL?`, обновляемый снаружи через `updateRoot(_:)`
    (`AppModel.wire()` при смене `projectRepoPath`), не замыкание на `settingsStore`.

## Как тестируем

- `FineTuneLogParser` — таблица строк лога (val, train, служебные без `Iter`, tqdm-мусор,
  `Saved adapter weights` — не точка).
- `FineTuneCheckpointPicker` — минимум val loss, ничья → ранняя итерация, пустой вход → nil.
- `FineTuneJSONL` — валидные/битые строки, не три сообщения, не тот порядок ролей.
- `FineTuneValidationParser` — успех и провал `validate.py` дословно, заголовок
  `ОШИБКИ (N):` не ошибка, двоеточия внутри текста, код 0 без строки «OK».
- `FineTuneOutputsReader` / `FineTuneOutputsIO` — оба формата `outputs.json` и оба
  поколения `.md` на **реальных файлах репозитория** (путь от `#filePath`, не от cwd),
  плюс синтетика в temp: битый JSON, нет `.md`, нет каталога. Обязательный кейс —
  `###`-заголовок внутри тела ответа не рвёт секции.
- `FineTuneStore` — миграция при новом поле `FineTuneRun`/`FineTuneCLIRun`, а также
  документа (`validations`, `minAssistantOverrides`); normalize зависшего `running` без
  живого pid; сборка документа — одна функция `makeDocument`, её зовут и `persistNow()`,
  и дебаунс-подписка (подписка на одно `@Published` уже однажды перезаписала соседние
  поля дефолтами — тест держит именно общую точку).
- `FineTuneRunner` — инжектированный `CLIRunner` (без реального `Process`): already-running
  через `adopt`, разбор `run.json`, регистрация в реестре (мок-реестр), неуспешный `stop`
  не снимает отслеживание.
- `FineTuneViewModel` — подхват своего/чужого прогона (в т.ч. с переиспользованным pid
  на завершённой записи), `installBest`/`stopCurrent(run:)` на неуспехе CLI, через
  инжектированные `FineTuneStore`/`FineTuneRunner` (реальный `Process` не запускается).
- `FineTuneRunTick` — накопление точек лога, ring-буфер хвоста, детект смерти pid,
  выбор `.finished`/`.failed` по `adapters.safetensors`, простановка `bestIter` — таблицей
  случаев, без таймера и без ViewModel.
- `FineTuneQuitGuard.activeRun` — свой `.running` прогон отдаётся, чужой
  (`isAdoptedExternally`) и не-`.running` — нет.
- `FineTuneEnvironment.probe` — таймаут и SIGTERM→SIGKILL: реальный `Process`, но дешёвые
  shell-скрипты (`exit 0`/`sleep`), не сеть и не mlx-lm (образец — `RunCommandToolTests`).
- Реальный `Process`/`train.py` в тестах не запускается — сеть/долгий тюн там неуместны.

## Частые ошибки прошлых задач

- Гашение прогона, отвязанного через «Оставить работать» — при `isDetached == true` оба
  сигнала обязаны быть no-op, иначе диалог выхода не выполняет своё обещание.
- Val-строка лога по ошибке разобрана train-шаблоном — обе начинаются `Iter N:`, val
  проверяется первым.
- `started_at` из `run.json` декодирован дефолтным `Date` без ручной конверсии эпохи —
  даты стартов уезжают на десятилетия.
- Операция (`installBest`, `stopCurrent`, будущие «над прогоном») привязана к внутреннему
  `tailedRunID`, а не к прогону, ВЫБРАННОМУ/ВКЛЮЧЁННОМУ в UI, — тихий no-op, если тайлинг
  не завершил подхват (кнопка в UI включается по стору, а не по тому же условию). Такие
  функции принимают прогон параметром.
- Результат `stop`/`installBest` отброшен (`_ = await runCLI(...)`) — неуспешный CLI
  выглядит обычным статусом (P6). Код возврата обязателен: `.stopped`/успех — только
  когда `status == 0`.
- Причина пустого списка датасетов определена через `errorText != nil` — используй
  `FineTuneDatasetsState`, не разбор errorText во View. `checkEnvironment()` errorText не
  трогает вовсе: подсказку показывает баннер напрямую по `environmentReady`.
- `FineTuneQuitGuard.probe` (или любой источник «активного» прогона для диалога/кнопки,
  которая гасит процесс) обязан отфильтровать `isAdoptedExternally` — иначе диалог выхода
  предлагает «Остановить обучение» для процесса, который приложению не принадлежит.
- Лог/статус в `FineTuneRunViews` привязаны к одному `viewModel.logTail`/`statusText` на
  весь экран — показ их для любого `displayedRun` без сверки с `tailedRunID` подсовывает
  хвост чужого прогона при переключении в истории.

## Куда не лезть

Сборку датасета из vault (`build_dataset.py`), регистрацию адаптера в `FunctionRouter`,
перенос автопроверок `style_checks.py`/`dictation_checks.py` в Swift, слепое сравнение
baseline и тюна с историей замеров — см. `tasks/BACKLOG.md` (48). Снятие baseline из
приложения (`baseline.py`) и генерация/правка `criteria.md` — сделаны задачей 83.

Контракт импорта (задача 83): импортированный датасет обязан проходить `validate.py`
без правок python — синтетический sidecar `*.meta.jsonl` (уникальный `source_post` на
пример), `system_prompt.txt` из канонического system первой строки, доля train 80%.

Просмотр baseline-ответов и рендер `criteria.md` — уже сделаны задачей 82, это не
«сравнение»: раздел показывает артефакты и ничего не пересчитывает. Числа в `criteria.md`
местами расходятся с фактическим пересчётом (документ заявляет «≥ 7/8: 6 из 10», на тех же
артефактах выходит 4 из 10) — это вопрос к тексту документа, а не повод считать метрики
в приложении.

## Политика по чужому прогону

Прогон, помеченный `isAdoptedExternally` (запущен из терминала, в `FineTuneStore` записи
нет), **никогда не гасится автоматически**: он не попадает ни в `BackgroundProcessRegistry`,
ни в пробу диалога выхода — инвариант №2. Ручная кнопка «Остановить» в разделе на нём
работает: это явное решение пользователя, а не побочный эффект Cmd+Q. Не путать эти два
случая при правках `FineTuneQuitGuard` и `FineTuneRunViews`.
