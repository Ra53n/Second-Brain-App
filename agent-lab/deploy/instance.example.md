# Координаты инстанса — шаблон

Реальные адреса держим в `deploy/instance.local.md` — он в `.gitignore`
(маска `*.local.md`) и в репозиторий не попадает. Скопируй этот файл туда и
подставь значения. Дисциплина взята из эталонного проекта Manager Assistant.

| Что | Значение |
|---|---|
| Хост VPS | `<vps>` |
| Домен | `<domain>` |
| Страница чата | `https://<domain>/lab/` |
| Админка | `https://<domain>/lab/admin` |
| Порт сервиса | 3300 (только 127.0.0.1) |
| systemd-юнит | `agent-lab.service` |
| Каталог | `/opt/agent-lab`, исходник `/opt/agent-lab-src` |
| Env | `/etc/agent-lab.env` |

## Соседи на той же машине — не трогать

| Маршрут | Порт | Сервис |
|---|---|---|
| `/agent/*` | 3100 | manager-agent |
| `/support/*` | 3200 | support-assistant |
| `/llm/*` | 11434 | Ollama через прокси |
| `/mcp` | 3000 | yougile-mcp |

## Выкладка

```bash
cd agent-lab && npm ci && npm test && npm run build
rsync -az --delete --exclude node_modules --exclude data --exclude '*.local.md' \
  ./ root@<vps>:/opt/agent-lab-src/
ssh root@<vps> 'bash /opt/agent-lab-src/deploy/deploy.sh'
```

Логи: `journalctl -u agent-lab -f`. Правка `/opt/agent-lab/dist` руками
запрещена — источник правды репозиторий.
