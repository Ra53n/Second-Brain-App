# llm-gateway

Гардед-прокси перед LLM (DeepSeek). Всё, что клиент шлёт в модель, проходит
через защитные слои; всё, что модель возвращает, проверяется перед отдачей.
Домашка курса «День 13 — LLM Gateway». Стек — Node 20 / TypeScript / Fastify /
SQLite (зеркало `agent-lab`).

## Что делает

- **Input guard** — детекция секретов regex-паттернами (API-ключи `sk-`/`ghp_`/
  `AKIA`/`AIza`/Slack, email, карты с проверкой Luhn, телефоны) + слои base64 и
  склейки разбитого секрета. Политика `block` (не пускать) или `mask`
  (заменить `[REDACTED_*]` и пропустить).
- **Output guard** — сгенерированные моделью ключи, утечка system prompt,
  секрет в URL/картинке, опасные команды. Вердикт pass / redact / block.
- **Rate limiting** — N запросов/мин на IP (за Caddy, реальный IP из XFF).
- **Cost tracking** — токены × тариф модели → USD, в аудит и в агрегат.
- **Аудит** — каждый запрос = строка в SQLite: находки, вердикты, токены,
  стоимость. Сырые секреты не пишутся никогда (только маскированный превью).

## Эндпоинты

| Метод | Путь | Доступ |
|---|---|---|
| GET | `/gw/health` | публично |
| GET | `/gw`, `/gw/` | публично (чат-ассистент) |
| POST | `/gw/chat` | публично, rate-limit по IP |
| GET | `/gw/admin` | публично (страница; данные — по токену) |
| GET/PUT | `/gw/admin/settings` | admin bearer |
| GET | `/gw/admin/audit`, `/gw/admin/interceptions` | admin bearer |
| GET | `/gw/admin/stats` | admin bearer |

Ключ DeepSeek, тарифы, персона и политика задаются в `/gw/admin` и лежат в
SQLite — не в env, не в git. В env только bootstrap (`GW_API_TOKEN`, порт, путь БД).

## Локальный запуск

```bash
npm ci && npm test && npm run build
GW_API_TOKEN=dev-token GW_PORT=3999 GW_DB_PATH=./data/gateway.db node dist/index.js
# открой http://127.0.0.1:3999/gw и http://127.0.0.1:3999/gw/admin
```

Без ключа DeepSeek чат с чистым промптом вернёт `config_error` — это ожидаемо;
блокировка секретов и админка работают и без ключа.

## Деплой на VPS

Идемпотентный, строго добавочный (порт 3400, маршрут `/gw/*`, юнит
`llm-gateway.service`). Соседей (`/lab`, `/support`, `/agent`, `/llm`) не трогает;
Caddyfile правится вставкой блока через `awk` с бэкапом и `caddy validate`.

С рабочей машины:

```bash
npm ci && npm test && npm run build
rsync -az --delete --exclude node_modules --exclude data --exclude dist ./ <user>@<VPS_HOST>:/opt/llm-gateway-src/
# dist собирается локально и копируется отдельно, либо собери на VPS
ssh <user>@<VPS_HOST> 'bash /opt/llm-gateway-src/deploy/deploy.sh'
```

deploy.sh при первой установке генерирует `GW_API_TOKEN` и печатает его. Дальше:
открой `/gw/admin`, вставь токен, задай ключ DeepSeek и политику гарда.

> Адрес VPS в репозитории не хранится — подставь свой при деплое.
