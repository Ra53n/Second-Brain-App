# Задача 85: чат раздела «Тюнинг» + оценка уверенности инференса

## Тип

фича

## Модель

Fable 5

## Цель

Дать пользователю полный цикл проверки тюненной модели, не выходя из приложения:
шестая вкладка «Чат» в разделе «Тюнинг» — изолированный мини-чат, где на фрагмент
транскрипта встречи модель извлекает поручения (строгий JSON `{"action_items": […]}`),
а каждый ответ проходит **пайплайн оценки уверенности** из четырёх подходов
(constraint-based → scoring → self-check → redundancy) с вердиктом OK / UNSURE / FAIL,
причинами и метриками (доп. вызовы, latency, токены). Плюс батч-прогон подборки из
valid-набора с отчётом-таблицей и сравнением baseline vs тюн.

Вторая цель — учебная (домашка «День 7: оценка уверенности и контроль качества
инференса»): результат — инференс с явной оценкой уверенности и контролем принятия
результата, доказанный замерами (сколько ответов отклонено, сколько повторных
инференсов, влияние на latency/cost) на корректных, пограничных и шумных входах.

## Зависимости

81, 82, 83, 84 (все `[x]`). Закрывает часть BACKLOG 48 (инференс тюна из приложения)
и BACKLOG 55 (прогон тюна на датасете встреч — выполняется в финале этой задачи).

## Допущения и corner-кейсы

- Чат доступен только для датасета `meetings` (единственный со строгим выходом);
  для остальных — заглушка `ContentUnavailableView`.
- Инференс — `mlx_lm.server` (OpenAI-совместимый HTTP, `127.0.0.1:18765`), управляемый
  child-процесс: регистрация в `BackgroundProcessRegistry`, ленивый старт, idle 10 мин,
  гашение на выходе (инвариант №2). Один сервер; смена baseline↔тюн — рестарт.
- Порт занят чужим процессом → ошибка пользователю; чужой сервер не адоптируем
  (вариант модели неизвестен) и не гасим.
- Взаимный guard по памяти (16 ГБ): тюн/baseline активен → чат и батч недоступны
  с внятной ошибкой; старт тюна/baseline сам гасит наш mlx-сервер.
- `.tuned` без `adapters/adapters.safetensors` → «Адаптер не найден — сначала
  прогоните тюн», сервер не стартует.
- `mlx_lm.server` недоступен (нет venv / нет модуля) → баннер с инструкцией установки,
  кнопки задизейблены, приложение не падает.
- Redundancy = 3 полных ответа → чат работает без стриминга (send), спиннер с
  прогрессом «Вызов N из M». Redundancy-прогоны — temperature 0.3 (как baseline).
- Confidence НЕ встраивается в основной промпт — не ломаем обученный контракт
  строгого JSON; scoring и self-check — отдельные вызовы. Модель, натасканная на
  единственный формат, может не ответить по контракту score-промпта — толерантные
  парсеры, сигнал «недоступен» (в причины, не FAIL): это измеримый результат домашки.
- Батч: детерминированная подборка 20 из 116 valid (10 непустых равномерным шагом,
  5 пустых, 5 «шумных» — самые длинные из оставшихся). Артефакты
  `finetune/meetings/confidence/{baseline,tuned}.{json,md}` + `summary.md` коммитятся.
- Крах посреди батча: отчёт пишется атомарно в конце; повторный запуск просто
  перезаписывает. Два одновременных батча исключены `isGenerating`-гейтом VM.
- Персистентность чата: `finetune-chat.json` в Application Support, паттерн P2
  (атомарная запись, карантин `.corrupt.json`, `decodeIfPresent` + дефолт, тест
  миграции). Битый файл → пустой чат, не краш.
- Кириллица/ё, null-поля, лишние ключи, ```-обёртки в ответах модели — покрыты
  тестами парсера (зеркало `actionitem_checks.parse`).
- Явно НЕ делаем: регистрацию адаптера в `FunctionRouter`/пикере моделей главного
  чата, fuse/GGUF/Ollama-экспорт, стриминг в мини-чате, RAG/инструменты/MCP в
  мини-чате, поддержку чата для датасетов постов и диктовки.

## Архитектура

По одобренному плану (`.claude/plans/whimsical-swimming-lark.md`, копия решений):

- **P1, чистое ядро** — `FineTune/Confidence/`: `ActionItemsAnswer` (типы + строгий
  парсер), `ConfidenceChecks` (порт 9 проверок `actionitem_checks.py` на Swift:
  reference-free для чата, reference-based для батча; Ratcliff-Obershelp порог 0.5),
  `ConfidencePrompts` (русские промпты scoring/self-check + толерантные парсеры),
  `RedundancyComparer` (мультимножества, agree/partial/disagree),
  `ConfidenceVerdict` (`ConfidenceReport: Codable` + редьюсер сигналов в вердикт),
  `ConfidenceBatch` (детерминированная подборка + рендер Markdown-отчётов).
- **Инфраструктура** — `MlxServerManager` (`@MainActor`, образец `OllamaManager`:
  спавн `-m mlx_lm.server`, health `GET /v1/models` до 120 с, idle, реестр);
  `MlxChatProvider` (`ChatProvider` поверх `POST /v1/chat/completions`, DTO из
  `OpenAIProvider.swift`, без ключа, инжектируемый транспорт). Осознанное отклонение
  от «всегда через FunctionRouter»: модель фиксирована предметом сравнения baseline/тюн.
- **Оркестрация** — `Confidence/ConfidencePipeline` (send → constraint (ранний FAIL) →
  redundancy → scoring → self-check → редьюсер), `ConfidenceBatchRunner` (valid.jsonl
  через `FineTuneJSONL` → пайплайн с эталоном → отчёты), `TuningChatViewModel`
  (P5: поколение, `persistNow()`).
- **P2** — `TuningChatStore`: `TuningChatMessage {id, role, content, report,
  modelVariant, createdAt}` → `finetune-chat.json`; для рендера маппится в
  `ChatMessage` → переиспользуем `MessageBubble` как есть.
- **UI** — `case chat` в `FineTuneTabBar`, `FineTuneChatViews` (статус сервера,
  переключатель baseline/тюн, `MessageBubble` + вердикт-чип с `DisclosureGroup`,
  ввод, секция батча). AX: подписи в `accessibilityValue`.
- Новые кейсы `FineTuneError`: `.mlxServerUnavailable`, `.tuneActive`, `.adapterMissing`.

## Объём

- `Sources/SecondBrain/FineTune/Confidence/` — 7 новых файлов (ядро + пайплайн).
- `Sources/SecondBrain/FineTune/`: `MlxServerManager.swift`, `MlxChatProvider.swift`,
  `TuningChatStore.swift`, `TuningChatViewModel.swift`, `ConfidenceBatchRunner.swift`,
  `FineTuneChatViews.swift` — новые; `FineTuneTabBar.swift`, `FineTuneViews.swift`,
  `FineTuneModels.swift` (ошибки), `FineTuneViewModel.swift` (guard) — правки.
- `Sources/SecondBrain/App/AppModel.swift` — wiring.
- `Tests/SecondBrainTests/` — новые классы по ядру, провайдеру, менеджеру, стору,
  пайплайну, VM, батчу.
- `smoke/impact-map.tsv`, `scripts/ui.sh` (DESTRUCTIVE-фразы) — строки.
- Артефакты живого прогона: `finetune/meetings/confidence/`.

## Вне объёма

- Регистрация тюна как модели главного чата / `FunctionRouter`.
- Fuse адаптера, GGUF, Ollama.
- Слепое сравнение с UI-оценкой человеком (остаток BACKLOG 48).
- Изменения тулчейна `finetune/*.py`.

## Критерии приёмки

1. Вкладка «Чат» видна для датасета «Встречи», для остальных — заглушка; смоук
   `./scripts/ui.sh` находит вкладку по `accessibilityValue`.
2. Сообщение в чате → ответ модели + вердикт-чип OK/UNSURE/FAIL с раскрываемыми
   причинами и метриками (вызовы, latency, токены); история переживает перезапуск
   (`finetune-chat.json`).
3. Переключатель baseline/тюн рестартует сервер; `.tuned` без адаптера — внятная
   ошибка без старта сервера.
4. mlx-сервер зарегистрирован в `BackgroundProcessRegistry`, гаснет по idle и на
   выходе; при активном тюне/baseline чат отказывает с ошибкой, старт тюна гасит сервер.
5. Все 4 подхода дают сигналы в отчёт; constraint-FAIL завершает пайплайн без
   дополнительных вызовов (`extraCalls == 0`).
6. Батч-прогон кнопкой: 20 примеров (10/5/5), отчёты `baseline.md`, `tuned.md`,
   `summary.md` с точностью vs эталон, долями FAIL/UNSURE, отклонёнными, повторными
   инференсами, наценкой latency.
7. Живой прогон выполнен: батч baseline → тюн (`FineTuneRunner.start` + `best
   --install`) → батч тюна → `summary.md`; сравнение baseline vs тюн в отчёте.
8. `./scripts/build.sh`, `./scripts/test.sh` зелёные; тест миграции стора; grep
   секретов пуст.

## Отчёт тестов

Покрытие по слоям (все тесты — моки/фикстуры/temp-файлы, сеть только в env-гейтед harness):

- Ядро `Confidence/`: `ConfidenceParserTests` (строгий парсер: битый JSON, ```-обёртка,
  лишние ключи, null/число в полях, юникод-эскейпы, эмодзи, вход 5000 повторов),
  `TextSimilarityTests` (эталоны посчитаны реальным python `difflib`),
  `ConfidenceChecksTests` (обе формы; 3 кейса reference-based сверены живым запуском
  `actionitem_checks.py`), `ConfidencePromptsTests` (мусорные ответы модели),
  `RedundancyComparerTests` (N=1/2/3, пустые списки, перестановка слов),
  `ConfidenceVerdictReducerTests` (таблица сигналов), `ConfidenceBatchTests`
  (детерминизм подборки 10/5/5, вырожденные входы, рендер).
- Декод «значений из будущего»: `ConfidenceVerdictDecodeRegressionTests`,
  `RedundancyAgreementDecodeRegressionTests` — незнакомая строка не карантинит документ.
- Инфраструктура: `MlxServerManagerTests` (регистрация в реестре до health, рестарт
  при смене адаптера, идемпотентный ensureRunning, гонка двух конкурентных стартов,
  stopNow во время starting — поздний health не воскрешает, idle, чужой порт),
  `MlxChatProviderTests` (фикстурный транспорт: успех/500/пустой choices/без usage),
  `TuningChatStoreTests` (round-trip, карантин битого, миграция старого JSON),
  `ConfidencePipelineTests` (ранний constraint-FAIL ⇒ extraCalls=0, счётчики вызовов,
  usage=nil, ошибка сети посреди redundancy пробрасывается, отмена),
  `TuningChatViewModelTests` (guard тюна, adapterMissing, гейты повторного
  send/runBatch, поколение), `ConfidenceBatchRunnerTests` (атомарность, всё-или-ничего,
  summary после второго варианта).
- Live-harness: `MlxLiveHarnessTests` — skip без `SB_MLX_LIVE=1`; с флагом гонит
  реальный батч через локальный `mlx_lm.server` (компенсация недоступного AX-смоука).

Дыры, найденные стадией тестирования и закрытые кодом: снисходительный декод
`ConfidenceVerdict`/`RedundancyAgreement`; двойной спавн сервера при конкурентных
`ensureRunning`; воскрешение сервера поздним health после `stopNow()`.

Итог `./scripts/test.sh` до финальных фиксов ревью: **1585 тестов, 0 падений,
1 пропущен (live-harness)**. Финальный прогон после фиксов ревью — в отчёте верификации.

## Вердикт ревью

Первый круг — NO-GO: незавершён живой прогон (критерий 7), нет «Отчёта тестов», ложный
комментарий про autojunk в `TextSimilarity`, `try?` глотал ошибку чтения `valid.jsonl`
в батч-раннере, 4 мелочи. Второй круг после фиксов — **GO**: все пункты проверены
ревьюером независимо (эталоны similarity пересчитаны реальным python, точечный прогон
56 тестов). Условие GO — зафиксировать хвост AX-смоука в «Результате» (выполнено ниже).

## Результат

Сделано по объёму, все 8 критериев приёмки закрыты (7 — доказательствами в репо,
критерий 1/2 частично — см. хвост AX):

- Вкладка «Чат» раздела «Тюнинг»: изолированный мини-чат для датасета «Встречи»
  (`FineTuneChatViews`, `TuningChatViewModel`, персистентность `finetune-chat.json`),
  переключатель baseline/тюн, вердикт-чип OK/UNSURE/FAIL с причинами и метриками.
- Пайплайн уверенности из 4 подходов (`FineTune/Confidence/`, чистое ядро P1):
  constraint-based (порт всех 9 проверок `actionitem_checks.py`, включая autojunk
  `difflib` — эталоны сверены с реальным python), scoring, self-check, redundancy ×3;
  редьюсер сигналов → вердикт; ранний constraint-FAIL не тратит доп. вызовов.
- `MlxServerManager` — управляемый `mlx_lm.server` (реестр процессов, idle 10 мин,
  двусторонний guard с тюном/baseline по памяти, генерация-guard от гонок);
  `MlxChatProvider` поверх OpenAI-совместимого API без ключа.
- Батч-прогон 20 примеров (10 непустых / 5 пустых / 5 шумных) из UI-кнопки и через
  env-гейтед `MlxLiveHarnessTests` (`SB_MLX_LIVE=1`).
- **Живой прогон выполнен целиком**: воссоздан `finetune/.venv` (mlx-lm 0.31.3);
  тюн 300 итераций (val loss 1.976 → 1.056, лучший — финальный чекпоинт, ~50 мин,
  пик 10.6 ГБ) — закрывает BACKLOG 55; батчи baseline и тюна одинаковыми проверками —
  артефакты `finetune/meetings/confidence/{baseline,tuned}.{json,md}` + `summary.md`;
  штатное сравнение `evaluate.py`: **тюн 50/65 против baseline 45/65 (+5)**, полный
  балл 4/10 примеров против 1/10, тюн лучше в 5 примерах, хуже в 3, поровну в 2.
- Замеры домашки (в отчётах): baseline — отклонено 6/20, тюн — 5/20; по 76 доп.
  вызовов на 20 примеров (redundancy+scoring+self-check); наценка latency ×4–10
  (сырые ответы ~1–5 с, полный пайплайн ~8–15 с; выбросы до 95 с — self-check
  у модели уходит в рассуждения на 4k токенов). Английские (непереведённые) фрагменты
  корпуса модель заваливает не-JSON ответом — constraint-фильтр ловит это FAIL'ом
  с extraCalls=0, ровно как задумано.

Отклонения и хвосты:
- **AX-смоук вкладки «Чат» не прогнан** — среда не даёт osascript разрешение
  Accessibility (нужно включить руками: System Settings → Privacy & Security →
  Accessibility). Компенсировано юнит-тестами VM и живым пайплайном через harness;
  прогнать `./scripts/ui.sh`-сценарий после выдачи разрешения.
- Батчи в этой сессии запускались через harness, не кнопкой UI (следствие того же
  ограничения AX); кнопки и wiring на месте, путь идентичен (тот же `ConfidenceBatchRunner`).
- Тюн запускался штатным CLI `train.py start` (контракт «файлы, не stdout» позволяет,
  приложение подхватывает прогон через adopt), не кнопкой UI.
- В `finetune/`-тулчейн не внесено ни одной правки (объём соблюдён); пути baseline.py:
  `--data`/`--out` резолвятся относительно `finetune/`, `--adapter` — нет, нужен
  абсолютный (грабля для следующих агентов).
- BACKLOG 56: база тюна для `MlxServerConfig` захардкожена, надо читать из `run.json`.

Важное следующим агентам: mlx_lm.server грузит модель лениво — health отвечает мгновенно,
первый инференс медленный; `prepare` без `--system` сравнивает с корневым
`finetune/system_prompt.txt` и даёт ложные ошибки для датасетов-подкаталогов.

Отчёт верификации: сборка чистая; **1598 тестов, 0 падений, 1 skipped** (live-harness);
критерии — по пунктам выше; артефакты живого прогона в `finetune/meetings/{confidence,tuned}/`;
grep секретов пуст; приложение переустановлено и перезапущено (pgrep подтверждён).
