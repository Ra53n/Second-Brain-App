# Support Assistant — саппорт-ассистент Second Brain (VPS-сервис)

AI-ассистент поддержки пользователей приложения Second Brain:

- отвечает на вопросы о продукте через **RAG** по FAQ и документации (markdown-база знаний, эмбеддинги через Ollama, векторы в SQLite);
- учитывает **контекст клиента**: логин-аккаунт связывается с CRM-записью по email, профиль и открытые тикеты автоматически попадают в системный промпт; детали модель добирает **MCP-инструментами** (встроенный stdio CRM-сервер поверх users.json/tickets.json);
- модель выбирается в админке: **локальная Ollama на VPS** (native /api/chat, num_ctx) или **облачная** (DeepSeek/OpenRouter, OpenAI-совместимый API);
- web-интерфейс: чат для пользователей + админка (настройки, редактор базы знаний с переиндексацией, CRM-редакторы, MCP-серверы, аккаунты);
- авторизация: cookie-сессии (scrypt-пароли, закрытая регистрация) + admin bearer-токен для скриптов; роль admin открывает админ-вкладки.

Технологии и паттерны портированы из сервиса `agent/` проекта Manager assistant: Node ≥20, TypeScript ESM, Fastify 4, better-sqlite3, официальный MCP SDK, vitest.

## Разработка

```bash
cd support
npm ci
npm test            # vitest (91 тест, без сети)
npm run build       # tsc → dist/
npm run dev         # локальный запуск (нужны SUPPORT_API_TOKEN и SESSION_SECRET в env)
```

Локальный запуск для отладки:

```bash
SUPPORT_API_TOKEN=dev SESSION_SECRET=dev \
SUPPORT_DB_PATH=/tmp/support.db SUPPORT_KB_DIR=./kb SUPPORT_CRM_DIR=./data-seed/crm \
npm run dev
# → http://127.0.0.1:3200/support/
```

## Устройство на VPS

| Что | Где |
|---|---|
| Код | `/opt/support-assistant` (dist + node_modules), исходники-зеркало `/opt/support-assistant-src` |
| Данные | `/opt/support-assistant/data`: `support.db` (SQLite), `kb/*.md`, `crm/*.json` — деплой их НЕ трогает |
| Bootstrap-env | `/etc/support-assistant.env` (secrets генерятся deploy.sh) |
| Юнит | `support-assistant.service` (systemd, hardened), слушает `127.0.0.1:3200` |
| Наружу | Caddy: `https://78-17-96-131.sslip.io/support/` (маршрут `/support/*`) |

Соседи по VPS (не трогать): manager-agent (`/agent/*` → 3100), llm-proxy (`/llm/*` → Ollama), yougile-mcp (`/mcp`). Ollama общая — `127.0.0.1:11434`.

## Деплой (с Mac)

```bash
cd support
npm ci && npm test && npm run build
rsync -az --delete --exclude node_modules --exclude data ./ root@78.17.96.131:/opt/support-assistant-src/
ssh root@78.17.96.131 'bash /opt/support-assistant-src/deploy/deploy.sh'
```

`deploy.sh` идемпотентен: system-пользователь, npm ci на месте, сид kb/crm только в пустые каталоги, env-секреты только при первом запуске, systemd-юнит, **вставка** маршрута Caddy (не перезапись файла!) с бэкапом + `caddy validate` + регрессия `/agent/health`.

Первый деплой дополнительно:

```bash
ssh root@78.17.96.131 'ollama pull bge-m3'   # эмбеддинги для русского (~1.2 GB)
ssh root@78.17.96.131 'cd /opt/support-assistant && \
  SUPPORT_DB_PATH=data/support.db node dist/scripts/create-user.js admin <пароль> --admin'
# демо-пользователь для проверки CRM-контекста:
ssh root@78.17.96.131 'cd /opt/support-assistant && \
  SUPPORT_DB_PATH=data/support.db node dist/scripts/create-user.js maria <пароль> --email=maria@example.com'
```

Затем в админке (`/support/` → вкладка «База знаний») — «Переиндексировать»; статус должен стать `ready`. CLI-альтернатива: `node dist/scripts/reindex.js` (с env как у сервиса).

## Грабли (проверено соседним сервисом)

- **Рестарт только `systemctl restart --no-block support-assistant`** — обычный restart вешает SSH-сессию, пока MCP-дети подключаются.
- **Caddyfile не перезаписывать целиком** — только вставка блока; у agent-версии скрипта перезапись однажды снесла `/llm/*`.
- Ollama держит одну модель в памяти (`OLLAMA_MAX_LOADED_MODELS=1`): переключение chat↔embed идёт со свопом модели в секунды — это норма, не зависание.
- Первый ответ после простоя медленный (холодная загрузка модели, десятки секунд) — SSE шлёт status-события.
- Логи: `journalctl -u support-assistant -f`.

## API (кратко)

Все маршруты под `/support`. Публично: `GET /health`, SPA, `POST /auth/login|logout`, `GET /auth/me`, `GET /llm/health`, а также гостевой чат `POST /guest/chat` (stateless, историю присылает клиент, rate-limit 12/мин) — аккаунт для обращения в поддержку не обязателен. Пользователь (cookie) или admin (bearer `SUPPORT_API_TOKEN`): CRUD `/chats`, `POST /chats/:id/messages` (SSE при `stream:true`: события `status`/`token`/`done`/`error`), `GET /llm/health`. Только admin: `/admin/settings`, `/admin/models`, `/admin/kb*`, `/admin/crm/*`, `/admin/mcp-servers*`, `/admin/users*`.

Секреты write-only: API-ключ LLM наружу не отдаётся (только `hasLlmKey` + последние 4 символа), пустой ключ в PATCH означает «не менять».
