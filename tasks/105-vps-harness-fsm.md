# Задача 105: FSM-harness на VPS — execution loop через LLM Gateway (День 14, часть 2)

## Тип

фича

## Модель

полная по объёму (новый сервис на VPS, свой персистентный стор, деплой), но код лежит
целиком в изолированной папке `harness/` вне Swift-приложения — приложение и его
инварианты не затрагиваются. Техлид ведёт сам по образцу задачи 103, `reviewer` на диф.

## Цель

Серверный execution loop рядом с gateway (задача 103): state-машина по образцу
`AgentPhaseReducer` desktop-приложения генерирует JS-код по задаче, гоняет цикл
«генерация → тесты (node --check) → security review → коммит» с итерацией, все
LLM-вызовы (генерация и security review) идут через `POST /gw/chat`. Защиты —
портами схемы приложения (ingress-санитизация, UNTRUSTED-границы, security-директива,
egress-guard) плюс input/output-гуарды самого gateway. Журнал показывает, что поймал
security step и что поймал gateway. Harness будут тестировать на секьюрность — есть
канарейка в системном промпте (детект «взлома») и README для тестировщика.

## Зависимости

- 103 (LLM Gateway) — все вызовы через него; журнал перехватов из `/gw/admin`.
- 88 (agent-lab) — донор TS-портов защит (`prompt/security.ts`, `guard/egress.ts`).

## Допущения и corner-кейсы

- FSM-паттерн берётся из `Sources/SecondBrain/Chat/AgentFSM/`: чистый редьюсер
  «контекст + сырой текст фазы → новый контекст», таблица переходов данными, два
  измерения state/status, бюджеты ретраев с форс-терминалом, persist после каждой
  фазы, `running → paused` на старте, resume идемпотентен (промпт собирается заново),
  поколение (`generation`) сверяется при записи (`UPDATE … WHERE id=? AND generation=?`).
- Генерируемый код — JS (Swift на VPS не собрать). «Тесты» = `node --check` синтаксиса,
  БЕЗ исполнения кода (сгенерённый код на VPS не запускается никогда — иначе RCE).
- Изоляция: код пишется в `data/workspaces/<runId>/`, там же одноразовый git.
- Порт 3500, маршрут `/harness/*` (свободны: заняты 3100/3200/3300/3400).
- LLM-ключа у harness нет — он ходит только в gateway (у того ключ в SQLite).
- `blocked` от gateway → терминал `gateway-blocked`, не бесконечный цикл. Невалидный
  JSON вердикта → один повтор «верни JSON», затем стоп `verdict-unparsed`. Обрыв
  ответа по maxTokens (незакрытый фенс) → фидбек «верни компактно». 429 → backoff по
  Retry-After; 5xx → ретрай. maxRounds=4, исчерпан → `stopped-limit`.
- Секреты в журнал не пишутся — маскированные превью (как аудит gateway).
- Канарейка (`HARNESS_CANARY`) — в env на VPS, не в git; в ответе после egress →
  флаг `pwned`, значение в админке не показывается.
- Адрес VPS в репозиторий и коммиты не пишется (BACKLOG п.67): `<VPS_HOST>` плейсхолдеры.

## Архитектура

- Сервис-зеркало `gateway/`: Fastify 4 + better-sqlite3 + vitest, тот же деплой-каркас
  (deploy.sh с awk-вставкой Caddyfile + бэкап + validate + регрессия соседей,
  hardened systemd unit, bootstrap-env с генерацией токена).
- Чистое ядро `src/fsm/`: `types.ts` (RunContext, RunState, RunStatus, таблица
  переходов, `allows`), `reducer.ts` (`normalizeBeforePhase` + `apply`), `prompts.ts`
  (промпт генерации, security-промпт под JS/Node, парсеры фенса и JSON-вердикта).
- Оркестратор `src/run/orchestrator.ts` — I/O: gwClient (единственная точка выхода на
  gateway), workspace (git init/commit, `node --check`), persist после фазы,
  gen-защита. Всё как в `ChatViewModel+AgentRun`, но серверно.
- Защиты `src/guard/`: копия `security.ts` из agent-lab, порт egress. Точки включения —
  как в приложении: sanitize+wrap на всём, что уходит в промпт из workspace; директива
  в каждый запрос обеих фаз; egress на каждом ответе LLM.
- Стор `src/store/`: WAL, миграции user_version; таблицы `runs` (контекст FSM целиком) и
  `steps` (журнал фаз с маскированными превью, находками, вердиктами).

## Объём

- `harness/` целиком: src (config, index, logger, http/*, web, fsm/*, run/*, guard/*,
  store/*, tasks), test/*, deploy/*, package.json, tsconfig, README.md, .gitignore.
- Строка `harness/data/` (и out) в `.gitignore`.
- Деплой на VPS, живой прогон 6 задач, сквозная проверка.
- Этот файл + строка в `00-INDEX.md`.

## Вне объёма

- Исполнение сгенерированного кода (только `node --check`).
- Fetch-инструмент/сеть внутри harness (SSRF-слой не нужен — сети из кода нет).
- Интеграция с desktop-приложением или скиллом `/execution-loop`.
- Правки самого gateway.

## Критерии приёмки

1. Все LLM-вызовы harness идут на `/gw/chat`; прямых обращений к DeepSeek нет.
2. FSM: генерация → node --check → security review → коммит с итерацией; Critical/High
   возвращают на генерацию с фидбеком «исправь: X в строке N»; Medium/Low → warning;
   чисто → коммит. maxRounds ограничивает, resume после рестарта поднимает прогон.
3. Защиты как в приложении: sanitize+UNTRUSTED на ingress, директива в каждом запросе,
   egress на каждом ответе; секреты в промпт не утекают (gateway маскирует).
4. Админка показывает настройки агента и журнал: находки security step (severity/строка),
   перехваты gateway, warnings, флаг `pwned`, стоимость.
5. Канарейка: детектор `pwned` срабатывает на контрольной утечке, молчит на честных.
6. README ведёт тестировщика от URL до запуска задачи и админки.
7. vitest зелёный (редьюсер — все переходы; гарды; миграции); соседние сервисы живы.
8. `git grep -I --cached -e 'sk-' -e 'ghp_' -e 'AIza'` пуст; адресов VPS в диффе нет.

## Отчёт тестов

- `npm test` (vitest): 50 тестов зелёные — таблица переходов FSM (все пары), чистое ядро
  редьюсера (happy path, обе развилки security, обрыв по maxTokens, gateway-blocked,
  verdict-unparsed, бюджет кругов), гарды (sanitize, egress, парсеры, secretVariants,
  преамбула secure/baseline), стор (round-trip, битый JSON → дефолты, «значение из
  будущего» → generating/paused, pauseRunning, защита поколением), оркестратор на моке
  gateway (committed, NO-GO→фикс на 2-м круге, verdict-unparsed, gateway-blocked, pwned).
- `npm run build` / `typecheck` — чисто (strict, noUncheckedIndexedAccess).
- Найден и исправлен реальный баг тестом: `pauseRunning` менял только колонку `status`,
  а `load` читает из `ctx_json` — рассинхрон ломал бы resume после старта; фикс через
  `json_set`, тест `save под устаревшим поколением` + `pauseRunning` это подтверждают.
- **Живая сквозная проверка на VPS** (реальный gateway → DeepSeek-v4):
  - `/harness/health` ok; деплой прошёл регрессию соседей (`/gw`, `/lab`, `/support`,
    `/agent` живы), Caddy пропатчен вставкой.
  - Прогоны 6 задач committed (t1, t3, t4, t5, t6) — код проходит `node --check`,
    security review чист (DeepSeek-v4 с security-директивой пишет безопасно), gateway
    маскирует плантованные `api_key`+`email` в КАЖДОМ вызове генерации (`inputAction=mask`).
  - **Перехват security step вживую** (baseline secure=false): t2-logging круг 1 →
    `high` «логирование тела/URL с PII» → NO-GO → новый круг → круг 2 → `2 high` → цикл
    возврата на генерацию с фидбеком работает ровно как в критерии домашки.
  - **Resume**: (а) resume упавшего прогона продолжил с текущего круга; (б) рестарт
    сервиса на живом прогоне → `running→paused` (recoverOnBoot) → resume → `finished`.
  - Все LLM-вызовы шли только на `/gw/chat` (у harness нет ключа DeepSeek); 502 от
    gateway под пиковой нагрузкой (много параллельных прогонов) обработаны graceful:
    ретраи → `failed` с errorText → resume, без зависаний.
  - Канарейка: детектор `pwned` покрыт юнит-тестом (утечка в ответе → флаг); в
    `/harness/admin/config` значение канарейки не раскрывается (только факт включения).

## Security-вердикт

Отдельный субагент по чек-листу стека (Node/TS/Fastify/SQLite). **Critical/High — нет.**
SQL параметризован (better-sqlite3), command injection закрыт (`execFile` без shell,
сгенерированный код только `node --check`, не исполняется), SSRF нет (только localhost
gateway), auth `timingSafeEqual`, таймауты и лимиты на месте. Два Medium исправлены до
коммита: (1) stderr `node --check` в фазе testing писался в публичный эндпоинт без
маскировки — сгенерированный код с плантованным секретом/канарейкой мог утечь → добавлен
`mask()`; (2) `trustProxy: true` давал обход rate-limit через `X-Forwarded-For` →
`trustProxy: 1`. Low: добавлена валидация UUID в маршрутах (defense-in-depth от подстановки
пути в Workspace).

## Вердикт ревью

**GO** (субагент `reviewer`). Блокирующих нет: паттерны gateway/agent-lab соблюдены
(чистое ядро, таблица переходов данными, снисходительный декодер, миграции user_version,
деплой строго добавочный с регрессией соседей), защиты — верные порты, секретов и адреса
VPS в диффе нет, 52 теста зелёные. Важное учтено: egress — порт+расширение (задокументировано
в шапке файла и здесь); добавлен интеграционный тест resume (`пауза running → resume →
committed`). Мелочи (опечатка «лимит», зависимости 88 в INDEX, заголовок) исправлены.

## Результат

Сделано по объёму полностью. Новый сервис `harness/` (Node/TS/Fastify/SQLite, зеркало
`gateway/`) задеплоен на VPS: порт 3500, маршрут `/harness/*`, страница запуска
`/harness/`, админка `/harness/admin` (настройки агента + журнал прогонов). FSM —
чистое ядро (редьюсер + таблица переходов) по образцу `AgentPhaseReducer`; оркестратор
с persist после фазы, `running→paused` на старте, resume и защитой поколением.

Проверено вживую (реальный gateway → DeepSeek-v4): 6 задач доходят до терминала; security
step ловит Critical/High и возвращает на генерацию с фидбеком (baseline t2-logging:
круг 1 → 1 high, круг 2 → 2 high); gateway маскирует плантованные секреты в каждом
вызове; resume после рестарта сервиса поднимает прогон до committed; UUID-валидация и
маскировка превью работают. Все LLM-вызовы идут только через `/gw/chat` (у harness нет
ключа DeepSeek).

Отклонения от плана: генерируемый код — JS (Swift на VPS не собрать); `report.py`-аналога
нет (журнал живёт в SQLite и админке). Замечание для следующих: 502 от gateway под
пиковой параллельной нагрузкой — узкое место DeepSeek, не harness; harness обрабатывает
graceful (ретраи → failed с errorText → resume). Секреты (admin-токен, канарейка) — только
в `/etc/llm-harness.env` на VPS, в git плейсхолдеры; README для тестировщика —
`harness/README.md` (реальный адрес подставляется вне git).
