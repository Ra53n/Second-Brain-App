#!/usr/bin/env bash
# deploy.sh — идемпотентная установка саппорт-ассистента на VPS. СТРОГО ДОБАВОЧНО:
# порт 3200, отдельный systemd-юнит, один маршрут Caddy /support/*. НЕ трогает
# manager-agent (/agent/*), llm-proxy (/llm/*), yougile-mcp и их маршруты.
#
# Запускать на VPS от root из распакованного исходника:
#   sudo bash /opt/support-assistant-src/deploy/deploy.sh
#
# Перед запуском dist/ должен быть собран (npm run build). Скрипт ставит prod-
# зависимости на месте (npm ci --omit=dev) — better-sqlite3 соберётся под Node VPS.

set -euo pipefail

APP_USER=supportassistant
APP_DIR=/opt/support-assistant
DATA_DIR=$APP_DIR/data
ENV_FILE=/etc/support-assistant.env
UNIT_FILE=/etc/systemd/system/support-assistant.service
CADDYFILE=/etc/caddy/Caddyfile
SUPPORT_PORT=3200

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
mkdir -p "$APP_DIR" "$DATA_DIR" "$DATA_DIR/kb" "$DATA_DIR/crm" "$APP_DIR/.npm" "$APP_DIR/.cache"

# ── 2. Выкладка приложения (data/ НЕ трогаем) ────────────────────────────────
log "Копирую dist/ и манифесты в $APP_DIR"
rm -rf "$APP_DIR/dist"
cp -r "$SRC_DIR/dist" "$APP_DIR/dist"
cp "$SRC_DIR/package.json" "$APP_DIR/package.json"
[ -f "$SRC_DIR/package-lock.json" ] && cp "$SRC_DIR/package-lock.json" "$APP_DIR/package-lock.json"

log "Ставлю prod-зависимости (npm ci --omit=dev)"
( cd "$APP_DIR" && npm ci --omit=dev --no-audit --no-fund )

# ── 3. Сид базы знаний и CRM — ТОЛЬКО если каталоги пусты ────────────────────
# Правки админа (файлы KB, users/tickets.json) при передеплое не затираются.
if [ -z "$(ls -A "$DATA_DIR/kb" 2>/dev/null)" ] && [ -d "$SRC_DIR/kb" ]; then
  log "Сид базы знаний → $DATA_DIR/kb"
  cp "$SRC_DIR/kb/"*.md "$DATA_DIR/kb/"
fi
if [ -z "$(ls -A "$DATA_DIR/crm" 2>/dev/null)" ] && [ -d "$SRC_DIR/data-seed/crm" ]; then
  log "Сид демо-CRM → $DATA_DIR/crm"
  cp "$SRC_DIR/data-seed/crm/"*.json "$DATA_DIR/crm/"
fi

# ── 4. Bootstrap-окружение (секреты не перезаписываем) ───────────────────────
gen_secret() { openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | xxd -p | tr -d '\n'; }

if [ ! -f "$ENV_FILE" ]; then
  TOKEN="$(gen_secret)"
  SESSION_SECRET="$(gen_secret)"
  log "Создаю $ENV_FILE c новым SUPPORT_API_TOKEN + SESSION_SECRET"
  cat > "$ENV_FILE" <<EOF
SUPPORT_API_TOKEN=$TOKEN
SESSION_SECRET=$SESSION_SECRET
SUPPORT_HOST=127.0.0.1
SUPPORT_PORT=$SUPPORT_PORT
SUPPORT_DB_PATH=$DATA_DIR/support.db
SUPPORT_KB_DIR=$DATA_DIR/kb
SUPPORT_CRM_DIR=$DATA_DIR/crm
OLLAMA_URL=http://127.0.0.1:11434
LOG_LEVEL=info
EOF
  chown root:"$APP_USER" "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  echo
  echo "==================================================================="
  echo " SUPPORT_API_TOKEN (admin-доступ к API из скриптов/curl):"
  echo "   $TOKEN"
  echo "==================================================================="
  echo
else
  log "$ENV_FILE уже есть — секреты сохранены."
fi

chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

# ── 5. systemd-юнит ───────────────────────────────────────────────────────────
log "Устанавливаю systemd-юнит"
cp "$SCRIPT_DIR/support-assistant.service" "$UNIT_FILE"
systemctl daemon-reload
systemctl enable support-assistant >/dev/null 2>&1 || true
systemctl restart --no-block support-assistant

# ── 6. Маршрут Caddy: ВСТАВКА, а не перезапись ────────────────────────────────
# ВАЖНО: в отличие от deploy.sh manager-agent, Caddyfile целиком НЕ пересоздаётся
# (тот подход однажды снёс маршрут /llm). Вставляем блок handle /support/* перед
# существующим handle /agent/* (или первым handle) внутри блока домена, с
# бэкапом и caddy validate. При любой странности — die с путём бэкапа.
patch_caddy() {
  [ -f "$CADDYFILE" ] || { log "Caddyfile не найден ($CADDYFILE) — добавь маршрут вручную (Caddyfile.snippet)."; return; }
  if grep -q '/support/' "$CADDYFILE"; then
    log "Caddy: маршрут /support/* уже есть — пропускаю."
    return
  fi
  local backup anchor
  backup="$CADDYFILE.bak.$(date +%s)"
  cp "$CADDYFILE" "$backup"

  # Точка вставки: строка с "handle /agent/*" (наш сосед) или первый "handle".
  anchor="$(grep -n 'handle /agent/\*' "$CADDYFILE" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || anchor="$(grep -n '^[[:space:]]*handle' "$CADDYFILE" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || die "Не нашёл блок handle в $CADDYFILE — добавь маршрут вручную (Caddyfile.snippet). Бэкап: $backup"

  log "Caddy: вставляю handle /support/* → 127.0.0.1:$SUPPORT_PORT (перед строкой $anchor)"
  awk -v line="$anchor" -v port="$SUPPORT_PORT" 'NR==line{
    print "    handle /support/* {"
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
sleep 2
log "Смоук: локальный /support/health"
curl -fsS --max-time 10 "http://127.0.0.1:$SUPPORT_PORT/support/health" && echo || die "Сервис не отвечает — смотри journalctl -u support-assistant"
log "Регрессия: /agent/health соседа (не должен сломаться)"
curl -fsS --max-time 10 "http://127.0.0.1:3100/agent/health" >/dev/null 2>&1 && echo "  /agent OK" || echo "  ВНИМАНИЕ: /agent/health не ответил — проверь manager-agent!"
log "Статус сервиса:"
systemctl --no-pager --lines=5 status support-assistant || true
log "Готово. Дальше: создай админа (dist/scripts/create-user.js), проверь модель эмбеддингов (ollama pull bge-m3) и запусти переиндексацию KB из админки."
