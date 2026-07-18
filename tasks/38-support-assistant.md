# 38. Саппорт-ассистент (VPS-сервис `support/`)

## Цель

AI-ассистент поддержки пользователей приложения Second Brain, развёрнутый на VPS как самостоятельный HTTP-сервис: отвечает на вопросы о продукте через RAG (FAQ + документация), учитывает контекст конкретного пользователя и его тикетов (CRM-данные в JSON через MCP), модель выбирается в админке — локальная Ollama на VPS или облачная (DeepSeek/OpenRouter). Web-интерфейс: чат для пользователей + админка; минимальная авторизация (логин/пароль, роль admin).

## Зависимости

Нет (полностью автономный подпроект; Swift-код приложения не трогается).

## Контекст

Референс — сервис `agent/` из проекта Manager assistant (Node 20 / TypeScript ESM / Fastify 4 / better-sqlite3 / vitest), уже развёрнутый на том же VPS 78.17.96.131 (порт 3100, маршрут `/agent/*`). Портируем его паттерны: auth (bearer + cookie-сессии + scrypt), LLM-клиенты (OpenAI-совместимый + native Ollama), MCP-хост (официальный SDK, stdio), чат-оркестрация (assembleMessages + FifoGate + SSE), идемпотентный deploy.sh + systemd + Caddy. RAG на сервере отсутствует — портируется из Swift (`RagChunker`, `RagVector`, `RagRetriever` этого репозитория).

Новый сервис живёт **рядом** с manager-agent: порт 127.0.0.1:3200, маршрут `/support/*`, юнит `support-assistant`, каталог `/opt/support-assistant`. Ollama и Caddy — общие.

## Объём работ

- [x] Каркас `support/`: package/tsconfig/config/logger/errors/db (миграция v1), `/support/health`.
- [x] Auth: scrypt-пароли, cookie-сессии (sha256-хеш в БД, TTL 30д), bearer-токен админа, `requireAdmin` (bearer ИЛИ cookie c isAdmin), CLI create-user, закрытая регистрация.
- [x] LLM: HttpLlmClient (DeepSeek/OpenRouter) + runToolLoop, OllamaClient (native /api/chat, стрим), ollamaToolAdapter (tools поверх native API), настройки в SQLite (write-only ключ).
- [x] RAG: чанкер по markdown-заголовкам, эмбеддинги через Ollama /api/embed (bge-m3), векторы Float32 в SQLite, ретрив с порогом/бюджетом/anti-injection-guard, переиндексация из админки.
- [x] CRM: users.json/tickets.json на VPS, stdio MCP-сервер (find_user/get_user/list_tickets/get_ticket/add_ticket_comment), авто-инъекция контекста клиента по email логина.
- [x] Чат: supportChatService (RAG + CRM-контекст + tool-loop + FifoGate + SSE), персистентные чаты.
- [x] SPA: чат с логином + админ-вкладки (Настройки / База знаний / CRM / MCP / Пользователи).
- [x] База знаний `kb/`: FAQ + документы по реальным фактам приложения (README, INSTALL, VISION, DATA-MODEL).
- [x] Деплой: deploy.sh (безопасная вставка маршрута Caddy, не перезапись!), systemd-юнит, env, деплой на VPS, e2e-проверка.

## Вне объёма

- Swift-код приложения Second Brain (не трогать).
- Сервис manager-agent на VPS (не трогать; регрессия `/agent/*` и `/llm/*` проверяется).
- Гостевой чат без логина, LLM-rewrite/rerank в RAG, стриминг внутри tool-итераций.

## Критерии приёмки

- `npm test` в `support/` зелёный (vitest: чанкер, вектора, ретривер, индексер, auth, tool-loop, adapter, CRM, MCP-хост, API).
- `https://78-17-96-131.sslip.io/support/health` отвечает; логин работает; админка настраивает провайдера/модель; reindex переводит KB в ready.
- E2e: пользователь с email из CRM спрашивает «почему не работает авторизация» → ответ учитывает его открытый тикет.
- Регрессия: `/agent/health` и `/llm` живы, manager-agent active.

## Результат

Сделано всё по плану; сервис развёрнут и принят на VPS.

**Что построено** (`support/`, Node 20 / TypeScript ESM / Fastify 4 / better-sqlite3 / vitest, ~91 тест):
- Портированы из manager-agent: config/logger/errors/db, auth (scrypt + cookie-сессии + bearer, новый `requireAdmin` = bearer ИЛИ cookie-админ), HttpLlmClient + runToolLoop, OllamaClient (native /api/chat + `/api/embed` для RAG), McpHostImpl, FifoGate/assembleMessages, SSE, идемпотентный deploy.sh, hardened systemd-юнит.
- Новое: RAG-модуль на TS (порт Swift `RagChunker`/`RagVector`/`RagRetriever` этого репо — чанкер по заголовкам, brute-force косинус, порог/бюджет/anti-injection-guard, embeddingTag-защита), `OllamaToolAdapter` (tool-calling через родной API с num_ctx), CRM на JSON (атомарная запись tmp+rename) + stdio MCP-сервер `crm` (5 инструментов, авто-регистрация при первом старте), авто-инъекция контекста клиента по email логина, SPA с чатом и 5 админ-вкладками.

**Продакшен**: `https://78-17-96-131.sslip.io/support/` — рядом с manager-agent (порт 3200, юнит `support-assistant`, `/opt/support-assistant`, env `/etc/support-assistant.env`). Caddy-маршрут вставлен ДОБАВОЧНО (awk-вставка перед `/agent/*` + validate + бэкап; перезапись файла как в agent-версии — запрещена, тот подход однажды снёс `/llm`). Эмбеддинги `bge-m3` (32 чанка, тег `bge-m3|1024`); KB и demo-CRM сидируются только в пустые каталоги.

**Приёмка**: vitest 91/91; `/support/health` и SPA отвечают; KB reindex → ready; тестовый поиск «почему не работает авторизация» → секция FAQ с score 0.76; e2e под maria@example.com: ответ ассистента (локальный qwen3:4b) начинается с её тикета t-101 и даёт решение про истёкший PAT из FAQ, с источниками. Регрессия: `/agent/health` 200, `/llm` жив (401 без токена), все юниты active.

**Отклонения и грабли для следующих агентов**:
- Баг первого деплоя: лишний `dirname` при вычислении пути `dist/mcp/crm-server.js` — CRM-MCP не поднимался («Connection closed»); исправлено в index.ts, конфиг в БД поправлен через PUT `/support/admin/mcp-servers`.
- Локальная модель на этом VPS (2 CPU, 3.9 ГБ RAM) МЕДЛЕННАЯ: полный ответ с RAG-промптом ~2к токенов — 5–10 минут (плюс своп моделей bge-m3↔qwen3, `OLLAMA_MAX_LOADED_MODELS=1` оставлен = 1 намеренно). Первый e2e упёрся в 10-минутный таймаут; после снижения `maxIterations` до 2 и подсказки в промпте («данные клиента уже в контексте — инструменты только при нехватке») qwen отвечает без tool-вызовов за ~9 мин. Для живого использования переключить провайдера на DeepSeek в админке (ключ write-only, хранится в SQLite).
- Стриминг-компромисс: с инструментами ответ не стримится потокенно (SSE шлёт status-события), без инструментов на ollama — честный токен-стрим.
- Рестарты только `systemctl restart --no-block support-assistant`.
- Swift-код не тронут (`swift build` зелёный); тесты Swift не гонялись — изменений в Sources/ нет.

## Дополнение (по запросу пользователя, та же дата)

Авторизация сделана НЕобязательной: гость пишет в поддержку без аккаунта.
- Новый публичный `POST /support/guest/chat` (stateless: историю присылает клиент, сервер не хранит; rate-limit 12/мин + FifoGate) и публичный `GET /support/llm/health`. RAG работает и для гостя; CRM-контекст — только у вошедших (по email).
- SPA: логин-гейт заменён модальным окном, гостевая история в localStorage, баннер «Гостевой режим…», кнопка «Войти» в шапке. Вход по-прежнему даёт серверные диалоги и ответы с учётом тикетов; админка — только для админов.
- Пункт «Вне объёма: гостевой чат без логина» отменён этим дополнением. Тесты: 94/94.

## Дополнение 2 (по запросу пользователя): центр обращений + фидбек-петля

- **Фидбек в чате**: после каждого ответа плашка «Ответ помог?» → «Да, решено» / «Нет, передать в поддержку». Отметка фиксируется в CRM оформленным обращением: не решено → тикет `open` с транскриптом диалога ([AI]-префикс у реплик ассистента), решено → `closed`. У вошедших тикет привязывается к чату (миграция v2: `chat_sessions.ticket_id`) — повторные отметки обновляют то же обращение. Гость при передаче в поддержку оставляет email (CRM-запись создаётся автоматически, id `u-NNN`/`t-NNN` — сквозная нумерация); «решено» без email принимается без записи в CRM. Эндпоинт `POST /support/feedback` (публичный, понимает cookie, rate-limit 10/мин).
- **Админка**: вкладка CRM стала «Обращениями» — список карточек (id, статус-бейдж, тема, клиент, дата, фильтр по статусу), разворачивается в переписку; там же смена статуса (открыт/в работе/закрыт) и ответ поддержки (`POST /admin/crm/tickets/:id/status|comment`). JSON-редакторы остались под спойлером «Продвинутый режим».
- **Промпт**: ассистент в конце каждого ответа спрашивает, решён ли вопрос, и напоминает про кнопки (дефолт в коде + обновлён на VPS).
- Тесты: 107/107. Проверено вживую: гостевой фидбек создал t-107 (клиент создан автоматически), админ перевёл в «в работе» и ответил.
