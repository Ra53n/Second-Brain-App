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
  валидации, порогов `--min-assistant`/`--max-reuse` и счётчиков baseline, плюс
  состояние экрана.
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
- `Confidence/EscalationCore` (P1) — каскадная эскалация (задача 91): дешёвая модель
  чата тюнинга не уверена (UNSURE/FAIL) → повтор на выбранной пользователем сильной.
  Порог настраивается (`EscalationTrigger`, задача 98) — дефолт `.failOnly` (только
  явный провал; UNSURE остаётся ответом дешёвой с жёлтым чипом), прежнее поведение —
  `.unsureOrFail` (UNSURE тоже эскалирует). Поле тредовое (`TuningChatThread.
  escalationTrigger`, симметрично `escalationEnabled`), снисходительный декодер:
  отсутствующее поле/незнакомое значение → `.failOnly` — понижение порога сознательно
  распространяется и на существующие треды (требование пользователя, не только на новые).
  `EscalationTargetResolver` — единственная точка контакта эскалации с
  `ProviderRegistry` (только для `EscalationTarget.kind == .registry`). Инвариант:
  `TuningChatMessage.report` — всегда отчёт ПОКАЗАННОГО ответа; отчёт дешёвой ступени
  при успешной эскалации лежит в `escalation.primaryReport`, при неудаче/
  недоступности — не дублируется (`nil`). Задача 95: сильная модель обязана быть НЕ ХУЖЕ
  дешёвой по вердикту (`ok > unsure > fail`, сравнение — только в `composeMessage`, не
  во View) — иначе `EscalationRecord.status == .notImproved`: показан ответ дешёвой,
  `report` = её отчёт (инвариант «report — показанный ответ» держится и здесь),
  `primaryReport` nil (не дублируется — показанный и есть primary), отчёт сильной — в
  `strongReport` (её стоимость всё равно входит в `TuningChatSessionStats`). Старый билд,
  не знающий `notImproved`, декодирует его в `.failed` (снисходительный декодер). Задача 93: цель может быть `.localTuned` —
  локальная тюненая модель поверх ВТОРОГО `mlx_lm.server` (`AppModel.mlxEscalationServerManager`,
  порт `MlxServerConfig.escalationPort` = 18766, независим от основного чата, гасится
  вместе с ним из `stopMlxServer`). `EscalationTargetResolver.resolve` ветвит на
  `.localTuned` ДО контакта с реестром через инжектируемый строитель `localTune`
  (в AppModel — `TuneSelection.selectTunedRun` по датасету meetings). Незнакомый/
  отсутствующий `kind` (файлы эпохи 91) декодируется в `.registry` молча.
- Задача 97 — пустой ответ валиден: вырожденный `{}` нормализуется пайплайном в
  `{"action_items": []}` (предупреждение → UNSURE, не hard-fail; повторы redundancy —
  та же нормализация); self-check при 0 пунктов задаёт ТОЛЬКО вопрос о пропущенных
  поручениях (`selfCheckEmptyPrompt`), per-item подтверждения на пустом списке — живой
  источник ложных FAIL (модель выдумывает пункты); `parseSelfCheck` клампит items к
  `expectedCount`. Причины «…недоступна» — только для включённого, но не давшего
  сигнала подхода (`ConfidenceSignals.*Enabled`). Осознанное отклонение от строгого
  python-контракта (`validate.py`/`evaluate.py` остаются строгими) — только в
  Swift-пайплайне чата/батча.
- `Confidence/StagedInference` (P1, задача 94) — декомпозиция primary-запроса на цепочку
  дешёвых стадий (говорящие → задачи с исполнителями → сроки → сборка), compact JSON между
  ними. `ConfidencePipeline.primary: PrimaryStrategy` (`.monolithic`/`.staged`) переключает
  только сборку primary-ответа: constraint/scoring/self-check и редьюсер видят единый
  `primaryText`. Redundancy повторяет ТОЛЬКО финальную стадию (не всю цепочку); непарсибельный
  compact-ответ промежуточной стадии не роняет запрос — `parseOk=false` идёт в
  `ConfidenceSignals.stageParseFailures`, редьюсер не поднимает вердикт выше UNSURE, финальную
  стадию и так проверяет constraint. Батч (`ConfidenceBatchRunner`) и эскалация (второй прогон
  `ConfidencePipeline`) не передают `primary` — остаются монолитом: сильной модели или прогону
  на всём датасете декомпозиция не нужна.
- `TuneSelection` (P1, задача 92) — мульти-модельные тюны одного датасета: `adapterDir(model:)`
  каталог нового прогона (`adapters/<slug>`, санитизация в `adapterDirName`),
  `selectTunedRun` — последний `.finished` прогон workdir+базы для чата `.tuned`,
  `chatBaseModels` — базы пикера (дефолты 3B/7B + завершённые прогоны), `legacyAdapterFallback` —
  правило легаси-пути (`adapters/adapters.safetensors` без per-model подкаталога): уместен
  только когда нет finished-записей ИМЕННО этой базы и база — дефолтная 7B (finished-прогон
  другой базы, например 3B, легаси-7B-адаптер не осиротит); иначе отсутствие тюна нужной
  базы — ошибка `FineTuneError.tunedRunMissing`, не тихая подмена чужим адаптером.

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
10. **Флаги CLI, у которых дефолт python расходится с нашим, задаются явно.**
    `baseline.py` по умолчанию берёт `temperature 0.7`, а все закоммиченные снимки
    сделаны на 0.3 — снимок из приложения без флага молча несопоставим с точкой
    отсчёта (однажды уже перезаписал её). `validate.py` считает дублями повтор
    ответа чаще трёх раз: для датасета классификации это ложное срабатывание, порог
    `--max-reuse` задаётся на датасет. Дефолт python — не наш дефолт (задача 84).
11. **Раннер не читает MainActor-состояние из своего актора.** Корень `finetune/` в
    `FineTuneRunner` — снимок `URL?`, обновляемый снаружи через `updateRoot(_:)`
    (`AppModel.wire()` при смене `projectRepoPath`), не замыкание на `settingsStore`.
12. **`run.json`/`train.log` — синглтоны на workdir, не на прогон** (задача 92): второй
    тюн того же датасета (другая база) их перезаписывает. Адаптеры per-model живут в
    `adapters/<slug>/` — это чинит независимость чекпоинтов, но не `train.log`: «Взять
    лучший» (`installBest`) обязан сверить показанный прогон с ТЕКУЩИМ run.json
    (`FineTuneViewModel.isCurrentRun`/`refreshCurrentRun`) — иначе val-кривая читается у
    чужого (более нового) прогона, а устанавливается в каталог старого.
13. **Ключ треда чата тюнинга — `"<variant>|<model>"`, не голый `variant`** (задача 92):
    `TuningChatViewModel.threadKey`, единая точка формирования — статистика/история
    baseline и тюна раздельны ПО КАЖДОЙ базе. Легаси-документы (`baseline`/`tuned` без
    `|`) мигрируют на 7B в `TuningChatDocument.migrateLegacyThreadKeys`.

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
  документа (`validations`, `minAssistantOverrides`, `maxReuseOverrides`); normalize зависшего `running` без
  живого pid; сборка документа — одна функция `makeDocument`, её зовут и `persistNow()`,
  и дебаунс-подписка (подписка на одно `@Published` уже однажды перезаписала соседние
  поля дефолтами — тест держит именно общую точку).
- `FineTuneRunner` — инжектированный `CLIRunner` (без реального `Process`): already-running
  через `adopt`, разбор `run.json`, регистрация в реестре (мок-реестр), неуспешный `stop`
  не снимает отслеживание; `start` кладёт `--adapter-dir` из `TuneSelection.adapterDir`,
  `installBest` — `--adapter-dir` из переданного вызывающим значения (не пересчитывает).
- `TuneSelection` — таблица случаев без I/O: слаг из id модели (санитизация `/`, пустая
  строка → «default»), выбор последнего `.finished` прогона по workdir+базе, distinct-список
  баз для пикера, легаси-fallback («нет finished-записей этой базы» + дефолтная 7B).
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
