# Задача 103: LLM Gateway — гардед-прокси перед DeepSeek (День 13)

## Тип

фича

## Модель

полная — триггеры: новый модуль (сервис `gateway/`), новые персистентные типы (settings,
requests-аудит), новый экран (чат + админка), новый маршрут деплоя на VPS.

## Цель

Домашка курса «День 13 — LLM Gateway»: HTTP-прокси между пользователем и LLM (DeepSeek)
с input guard (детекция секретов regex'ами: API-ключи, email, карты, телефоны; блокировка
или маскирование), output guard (галлюцинированные секреты, утечка system prompt,
подозрительные URL/команды), полным аудит-логом, rate limiting и cost tracking. Плюс
переделка «онлайн-чата»: вместо синтетической red-team персоны — чистый полезный
ассистент; гарды работают молча, весь аудит — в админке. agent-lab (задача 88) остаётся
жить и служит бэкендом-мишенью в интеграционном тесте («gateway перед lab»).

## Зависимости

- 88 (agent-lab) — донор всего каркаса: `HttpLlmClient` с ретраями, Fastify+rate-limit,
  SQLite+миграции, `egress.ts` (`secretVariants`/`neutralize`), логгер с redaction,
  деплой-обвязка (awk-вставка в Caddyfile с бэкапом и validate).
- 26 (OpenRouter/DeepSeek) — формат DeepSeek API, модель `deepseek-chat`.

## Допущения и corner-кейсы

- Решение владельца (интервью): архитектура — «gateway перед lab» (отдельный сервис,
  agent-lab сохраняется); чат — чистый ассистент, аудит только в админке.
- Стек — TS/Fastify (зеркало agent-lab), не FastAPI: обвязка уже отлажена на этом VPS.
- Порт 3400, маршрут `/gw/*` — свободны (разведка: заняты 3100/3200/3300, `/agent|support|lab|llm|mcp`).
- Ключ DeepSeek — в SQLite через админку (write-only, наружу `hasKey`+last4), не в env, не в git.
- Пустой промпт → 400 validation_error. Нет ключа → понятная ошибка config_error, в LLM не ходим.
- Карты только с валидным Luhn (иначе ложные срабатывания на любые 16 цифр).
- Base64-слой: декодируются только правдоподобные blob'ы (длина ≥16, валидный alphabet),
  находки помечаются `encoding: base64`.
- Разбитый секрет (`"sk-" + "proj-abc"`): нормализующий проход склейки консервативен —
  только кавычки/`+`/пробелы между фрагментами, похожими на разорванный токен.
- Политика per-тип: `block` | `mask` (домашка требует оба режима), настраивается в админке.
- Rate limit N/мин на IP (`trustProxy` за Caddy), настраивается; превышение → 429.
- Cost: цены за 1M токенов (вход/выход) в настройках, дефолты для `deepseek-chat`;
  cache-hit цены DeepSeek не моделируем (вне объёма).
- Стриминга нет (`stream:false`) — output guard работает на полном ответе.
- Публичный адрес VPS в git не попадает (урок из agent-lab/REPORT.md — утекал дважды).

## Архитектура

Новая папка `gateway/` — зеркало agent-lab. Переиспользуется с адаптацией: `openaiClient.ts`
(ядро прокси), `config.ts` (bootstrap: GW_API_TOKEN, SESSION_SECRET, host/port/db),
`db.ts` (WAL+миграции), `app.ts` (Fastify, trustProxy, error-handler, rate-limit
global:false), `logger.ts` (redaction), `egress.ts` (в составе output guard),
`errors.ts`, `authMiddleware.ts` (только admin bearer, cookie-сессий нет — чат публичный
за rate-limit), `deploy/*` (порт 3400, `/gw/*`, юнит llm-gateway.service, awk-вставка).

Чистое ядро (P1), без I/O, тестируется исчерпывающе:
- `src/guard/inputGuard.ts` — `detectSecrets`, `maskSecrets`, `applyInputPolicy`;
- `src/guard/outputGuard.ts` — `checkOutput` (секреты в ответе, утечка system prompt,
  URL с секретом через `neutralize`, опасные команды) → `pass | redact | block`;
- `src/cost/pricing.ts` — `computeCost(usage, prices)`.

Оркестратор `src/chat/gatewayService.ts`: input guard → (block? warning без LLM : forward
masked) → `HttpLlmClient` → output guard → cost → `auditRepo.log` → ответ.
Хранение: `settings` (id=1) + `requests` (аудит: findings, usage, cost_usd, blocked).
HTTP: `POST /gw/chat` (public, rate-limit), `GET /gw/health`, admin: audit/settings/stats.
Web: две inline-HTML страницы (чат-ассистент; админка: аудит перехватов + стоимость).

## Объём

- [x] `gateway/` целиком: src (config, logger, domain, llm, guard×2, cost, chat, store×3,
      http×4, web), package.json, tsconfig.json, README.md
- [x] Тесты vitest ≥10 кейсов по домашке (офлайн, fetch инжектируется) + rate-limit + cost
- [x] Интеграционный тест «gateway перед lab»: бэкенд-мишень имитирует утечку канарейки
      в URL → output guard блокирует
- [x] `gateway/REPORT.md`: таблица «что поймали / что пропустили» + примеры логов перехвата
- [x] `gateway/deploy/`: deploy.sh (порт 3400, /gw/*), llm-gateway.service, Caddyfile.snippet,
      env.example
- [x] Строка в 00-INDEX.md; пункты в BACKLOG (задвоенный №88, утечка адреса VPS) — фиксация,
      не починка

## Вне объёма

- Правки agent-lab, support, manager-agent.
- Стриминг SSE, cache-hit-цены DeepSeek, multi-provider роутинг.
- Деплой на VPS выполняет владелец (rsync+ssh) — скрипты готовим, сами не запускаем
  без его команды.

## Критерии приёмки

1. `cd gateway && npm test` зелёный; ≥10 тест-кейсов домашки зафиксированы в REPORT.md
   с итогом «поймали/пропустили».
2. Промпт с секретом (`sk-…`, AKIA, карта с Luhn, email, телефон, base64, разбитый) при
   политике block → 200 с warning, LLM-вызова нет, запись в аудит.
3. При политике mask → в LLM уходит `[REDACTED_*]`-версия (доказательство: захваченный
   fetch-боди в тесте), ответ возвращается.
4. Чистый промпт проходит насквозь без изменений.
5. Output guard: ответ модели с `sk-…`-ключом редактируется; URL с секретом вырезается;
   утечка system prompt блокируется.
6. Rate limit: N+1-й запрос в минуту с одного IP → 429.
7. Каждый запрос в аудите: findings, токены, cost_usd; админ-stats отдаёт сумму.
8. `git grep -I --cached -e 'sk-' -e 'ghp_' -e 'AIza' -e 'AKIA' -- gateway` — совпадения
   только в regex-паттернах гарда и тест-фикстурах с заведомо фейковыми значениями.

## Отчёт тестов

`cd gateway && npm test` — **48 тестов, все зелёные** (vitest, офлайн, fetch инжектируется).
Покрыто: 6 файлов — `inputGuard` (16: 10 кейсов домашки + контроль ложных срабатываний +
маскирование + политика block/mask/allow/byType), `outputGuard` (6), `pricing` (3),
`settings` (6: снисходительный декодер + write-only ключ), `gatewayService` (9: block/mask/
allow, output-block, cost, нет ключа, пустой промпт, суточный лимит, DLP-инвариант,
сценарий «gateway перед lab»), `api` (8: health, чат, admin-скоуп, rate-limit 429 в едином
конверте). Таблица «поймали/пропустили» и границы — в `gateway/REPORT.md`.
Дыры: осознанные границы задокументированы в REPORT (голый ряд цифр как телефон, склейка
только через литералы, base64 только одинарный, утечка промпта по дословному окну).

## Отчёт живого прогона

Локальный смоук `node dist/index.js` (без реального ключа DeepSeek): `/gw/health` → ok;
PUT `/gw/admin/settings` меняет политику, ключ наружу не отдаётся (`hasLlmKey:false`);
POST `/gw/chat` с `AKIA…` + картой при policy=block → заблокирован, в LLM не ушло, в аудите
маскированный превью `[REDACTED_API_KEY]`/`[REDACTED_CARD]`; чистый промпт без ключа →
`config_error` 503; `/gw/admin/stats` и `/interceptions` показывают перехват; admin без
токена → 401. Живой вызов DeepSeek через прокси — на VPS после ввода ключа в `/gw/admin`.

## Вердикт ревью

Субагент `reviewer` (read-only): блокирующих и важных нет. Мелочи (429 не в едином
конверте; непокрытый декодер настроек; лишняя работа output-гарда при block) — **устранены**
после вердикта: `errorResponseBuilder` → AppError(busy,429) в общий конверт, `settings.test.ts`
на fallback декодера, ранний выход `checkOutput` при block. Итог — **GO**.

## Результат

Сделан отдельный сервис `gateway/` (Node/TS/Fastify/SQLite, зеркало agent-lab) — гардед-прокси
перед DeepSeek. Ядро (чистые функции P1): `inputGuard` (regex-детекция ключей sk-/ghp_/AKIA/
AIza/Slack + email + карты с Luhn + телефоны, слои base64 и склейки разбитого секрета,
маскирование, политика block/mask/byType), `outputGuard` (ключи в ответе, утечка system prompt
скользящим окном, секрет в URL через egress, опасные команды), `cost/pricing` (токены → USD по
тарифу модели). Оркестратор `gatewayService` собирает путь input→LLM→output→cost→аудит.
HTTP: `/gw/chat` (rate-limit по IP), `/gw/admin/*` (bearer), `/gw` и `/gw/admin` — чистый
чат-ассистент и панель аудита. Персистентность: `settings` (id=1, ключ write-only) + `requests`
(аудит без сырых секретов). Деплой строго добавочный: порт 3400, `/gw/*`, юнит, awk-вставка в
Caddyfile с бэкапом+validate, регрессия соседей.

**Важное для следующих агентов:**
- Псевдо-рандома в чате agent-lab не было — он реально ходит в DeepSeek; «фейковость» —
  синтетический red-team сценарий задачи 88. Пользователь захотел отдельный gateway перед lab
  с чистым ассистентом, а не переделку лаборатории. agent-lab не тронут.
- rate-limit `max` должна быть SYNC-функцией, а `buildApp` — `await`-ить `app.register(rateLimit)`
  ДО регистрации маршрутов, иначе per-route лимиты не применяются (проверено).
- Ключ DeepSeek и адрес VPS в git не попадают. Тарифы DeepSeek в `pricing.ts`/настройках —
  сверить с актуальным прайсом перед продом.
- Деплой на VPS выполняет владелец (rsync в `/opt/llm-gateway-src` + `deploy.sh`), ключ вводится
  в `/gw/admin` после установки.
