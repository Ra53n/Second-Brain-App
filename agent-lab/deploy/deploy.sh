#!/usr/bin/env bash
# deploy.sh — идемпотентная установка agent-lab на VPS. СТРОГО ДОБАВОЧНО:
# порт 3300, отдельный systemd-юнит, один маршрут Caddy /lab/*. НЕ трогает
# manager-agent (/agent/*), support-assistant (/support/*), llm-proxy (/llm/*),
# yougile-mcp и их маршруты.
#
# Запускать на VPS от root из распакованного исходника:
#   sudo bash /opt/agent-lab-src/deploy/deploy.sh
#
# Перед запуском dist/ должен быть собран (npm run build). Скрипт ставит prod-
# зависимости на месте (npm ci --omit=dev) — better-sqlite3 соберётся под Node VPS.

set -euo pipefail

APP_USER=agentlab
APP_DIR=/opt/agent-lab
DATA_DIR=$APP_DIR/data
ENV_FILE=/etc/agent-lab.env
UNIT_FILE=/etc/systemd/system/agent-lab.service
CADDYFILE=/etc/caddy/Caddyfile
LAB_PORT=3300

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(dirname "$SCRIPT_DIR")"

log() { echo -e "\033[1;34m[deploy]\033[0m $*"; }
die() { echo -e "\033[1;31m[deploy] ОШИБКА:\033[0m $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "Запускай от root (sudo)."
[ -f "$SRC_DIR/dist/index.js" ] || die "Нет $SRC_DIR/dist/index.js — сначала собери: npm ci && npm run build"
command -v node >/dev/null || die "Не найден node."

# ── 1. Пользователь и каталоги ───────────────────────────────────────────────
if ! id "$APP_USER" >/dev/null 2>&1; then
  log "Создаю системного пользователя $APP_USER"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"
fi
mkdir -p "$APP_DIR" "$DATA_DIR" "$DATA_DIR/corp" "$APP_DIR/.npm" "$APP_DIR/.cache"

# ── 2. Выкладка приложения (data/ НЕ трогаем) ────────────────────────────────
log "Копирую dist/ и манифесты в $APP_DIR"
rm -rf "$APP_DIR/dist"
cp -r "$SRC_DIR/dist" "$APP_DIR/dist"
cp "$SRC_DIR/package.json" "$APP_DIR/package.json"
[ -f "$SRC_DIR/package-lock.json" ] && cp "$SRC_DIR/package-lock.json" "$APP_DIR/package-lock.json"

log "Ставлю prod-зависимости (npm ci --omit=dev)"
( cd "$APP_DIR" && npm ci --omit=dev --no-audit --no-fund )

# ── 3. Сид подсадной базы — ТОЛЬКО если каталог пуст ─────────────────────────
# Правки владельца (свои документы, свои «секреты») при передеплое не затираются.
if [ -z "$(ls -A "$DATA_DIR/corp" 2>/dev/null)" ] && [ -d "$SRC_DIR/data-seed/corp" ]; then
  log "Сид подсадной внутренней базы → $DATA_DIR/corp"
  cp -r "$SRC_DIR/data-seed/corp/." "$DATA_DIR/corp/"
fi

# ── 4. Bootstrap-окружение (секреты не перезаписываем) ───────────────────────
gen_secret() { openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | xxd -p | tr -d '\n'; }

if [ ! -f "$ENV_FILE" ]; then
  TOKEN="$(gen_secret)"
  SESSION_SECRET="$(gen_secret)"
  ACCESS_CODE="$(openssl rand -hex 6 2>/dev/null || echo "lab-$(date +%s)")"
  log "Создаю $ENV_FILE c новыми LAB_API_TOKEN + SESSION_SECRET + кодом доступа"
  cat > "$ENV_FILE" <<EOF
LAB_API_TOKEN=$TOKEN
SESSION_SECRET=$SESSION_SECRET
LAB_HOST=127.0.0.1
LAB_PORT=$LAB_PORT
LAB_DB_PATH=$DATA_DIR/lab.db
LAB_CORP_DIR=$DATA_DIR/corp
LAB_ACCESS_CODE=$ACCESS_CODE
LOG_LEVEL=info
EOF
  chown root:"$APP_USER" "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  echo
  echo "==================================================================="
  echo " LAB_API_TOKEN (админка /lab/admin, curl, атака-смоук):"
  echo "   $TOKEN"
  echo " Код доступа для атакующих (страница /lab/):"
  echo "   $ACCESS_CODE"
  echo "==================================================================="
  echo
else
  log "$ENV_FILE уже есть — секреты сохранены."
fi

chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

# ── 5. systemd-юнит ───────────────────────────────────────────────────────────
log "Устанавливаю systemd-юнит"
cp "$SCRIPT_DIR/agent-lab.service" "$UNIT_FILE"
systemctl daemon-reload
systemctl enable agent-lab >/dev/null 2>&1 || true
# Только --no-block: обычный restart вешает SSH-сессию до готовности сервиса.
systemctl restart --no-block agent-lab

# ── 6. Маршрут Caddy: ВСТАВКА, а не перезапись ────────────────────────────────
# Caddyfile целиком НЕ пересоздаётся (подход manager-agent однажды снёс /llm).
# Вставляем блок handle /lab/* перед первым существующим handle внутри блока
# домена, с бэкапом и caddy validate. При любой странности — die с путём бэкапа.
patch_caddy() {
  [ -f "$CADDYFILE" ] || { log "Caddyfile не найден ($CADDYFILE) — добавь маршрут вручную (Caddyfile.snippet)."; return; }
  if grep -q '/lab/' "$CADDYFILE"; then
    log "Caddy: маршрут /lab/* уже есть — пропускаю."
    return
  fi
  local backup anchor
  backup="$CADDYFILE.bak.$(date +%s)"
  cp "$CADDYFILE" "$backup"

  anchor="$(grep -n 'handle /support/\*' "$CADDYFILE" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || anchor="$(grep -n 'handle /agent/\*' "$CADDYFILE" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || anchor="$(grep -n '^[[:space:]]*handle' "$CADDYFILE" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || die "Не нашёл блок handle в $CADDYFILE — добавь маршрут вручную (Caddyfile.snippet). Бэкап: $backup"

  log "Caddy: вставляю handle /lab/* → 127.0.0.1:$LAB_PORT (перед строкой $anchor)"
  awk -v line="$anchor" -v port="$LAB_PORT" 'NR==line{
    print "    handle /lab/* {"
    print "        reverse_proxy 127.0.0.1:" port
    print "    }"
  } {print}' "$backup" > "$CADDYFILE"

  if command -v caddy >/dev/null; then
    caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
      || { cp "$backup" "$CADDYFILE"; die "caddy validate не прошёл — Caddyfile восстановлен из бэкапа $backup."; }
  fi
  systemctl reload caddy
}
patch_caddy

# ── 7. Смоук-проверки: наш сервис + регрессия соседей ────────────────────────
# После restart --no-block сервис поднимается несколько секунд — ждём.
sleep 5
log "Смоук: локальный /lab/health"
curl -fsS --max-time 10 "http://127.0.0.1:$LAB_PORT/lab/health" && echo || die "Сервис не отвечает — смотри journalctl -u agent-lab"
log "Регрессия соседей (не должны сломаться)"
curl -fsS --max-time 10 "http://127.0.0.1:3200/support/health" >/dev/null 2>&1 && echo "  /support OK" || echo "  ВНИМАНИЕ: /support/health не ответил — проверь support-assistant!"
curl -fsS --max-time 10 "http://127.0.0.1:3100/agent/health"   >/dev/null 2>&1 && echo "  /agent OK"   || echo "  ВНИМАНИЕ: /agent/health не ответил — проверь manager-agent!"
log "Статус сервиса:"
systemctl --no-pager --lines=5 status agent-lab || true
log "Готово. Дальше: открой /lab/admin, вставь LAB_API_TOKEN, задай ключ LLM и уровень защиты."
