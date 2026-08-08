#!/usr/bin/env bash
# deploy.sh — идемпотентная установка llm-harness на VPS. СТРОГО ДОБАВОЧНО:
# порт 3500, отдельный systemd-юнит, один маршрут Caddy /harness/*. НЕ трогает
# manager-agent (/agent), support-assistant (/support), agent-lab (/lab),
# llm-gateway (/gw) и их маршруты.
#
# Запускать на VPS от root из распакованного исходника:
#   sudo bash /opt/llm-harness-src/deploy/deploy.sh
#
# Перед запуском dist/ должен быть собран (npm run build). Скрипт ставит prod-
# зависимости на месте (npm ci --omit=dev) — better-sqlite3 соберётся под Node VPS.

set -euo pipefail

APP_USER=llmharness
APP_DIR=/opt/llm-harness
DATA_DIR=$APP_DIR/data
ENV_FILE=/etc/llm-harness.env
UNIT_FILE=/etc/systemd/system/llm-harness.service
CADDYFILE=/etc/caddy/Caddyfile
HARNESS_PORT=3500

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(dirname "$SCRIPT_DIR")"

log() { echo -e "\033[1;34m[deploy]\033[0m $*"; }
die() { echo -e "\033[1;31m[deploy] ОШИБКА:\033[0m $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "Запускай от root (sudo)."
[ -f "$SRC_DIR/dist/index.js" ] || die "Нет $SRC_DIR/dist/index.js — сначала собери: npm ci && npm run build"
command -v node >/dev/null || die "Не найден node."
command -v git >/dev/null || die "Не найден git (harness делает git init/commit в рабочих копиях)."

# ── 1. Пользователь и каталоги ───────────────────────────────────────────────
if ! id "$APP_USER" >/dev/null 2>&1; then
  log "Создаю системного пользователя $APP_USER"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"
fi
mkdir -p "$APP_DIR" "$DATA_DIR" "$APP_DIR/.npm" "$APP_DIR/.cache"

# ── 2. Выкладка приложения (data/ НЕ трогаем) ────────────────────────────────
log "Копирую dist/ и манифесты в $APP_DIR"
rm -rf "$APP_DIR/dist"
cp -r "$SRC_DIR/dist" "$APP_DIR/dist"
cp "$SRC_DIR/package.json" "$APP_DIR/package.json"
[ -f "$SRC_DIR/package-lock.json" ] && cp "$SRC_DIR/package-lock.json" "$APP_DIR/package-lock.json"

log "Ставлю prod-зависимости (npm ci --omit=dev)"
( cd "$APP_DIR" && npm ci --omit=dev --no-audit --no-fund )

# ── 3. Bootstrap-окружение (секреты не перезаписываем) ───────────────────────
gen_secret() { openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | xxd -p | tr -d '\n'; }
gen_canary() { echo "HARNESS_CANARY_$(openssl rand -hex 8 2>/dev/null || head -c8 /dev/urandom | xxd -p | tr -d '\n')"; }

if [ ! -f "$ENV_FILE" ]; then
  TOKEN="$(gen_secret)"
  CANARY="$(gen_canary)"
  log "Создаю $ENV_FILE c новыми HARNESS_API_TOKEN + HARNESS_CANARY"
  cat > "$ENV_FILE" <<EOF
HARNESS_API_TOKEN=$TOKEN
HARNESS_HOST=127.0.0.1
HARNESS_PORT=$HARNESS_PORT
HARNESS_DB_PATH=$DATA_DIR/harness.db
GW_URL=http://127.0.0.1:3400/gw
HARNESS_CANARY=$CANARY
LOG_LEVEL=info
EOF
  chown root:"$APP_USER" "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  echo
  echo "==================================================================="
  echo " HARNESS_API_TOKEN (админка /harness/admin, curl):"
  echo "   $TOKEN"
  echo " HARNESS_CANARY (цель атаки — тестировщику НЕ показывать):"
  echo "   $CANARY"
  echo "==================================================================="
  echo
else
  log "$ENV_FILE уже есть — секреты сохранены."
fi

chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

# ── 4. systemd-юнит ───────────────────────────────────────────────────────────
log "Устанавливаю systemd-юнит"
cp "$SCRIPT_DIR/llm-harness.service" "$UNIT_FILE"
systemctl daemon-reload
systemctl enable llm-harness >/dev/null 2>&1 || true
systemctl restart --no-block llm-harness

# ── 5. Маршрут Caddy: ВСТАВКА, а не перезапись ────────────────────────────────
patch_caddy() {
  [ -f "$CADDYFILE" ] || { log "Caddyfile не найден ($CADDYFILE) — добавь маршрут вручную (Caddyfile.snippet)."; return; }
  if grep -q '/harness/' "$CADDYFILE"; then
    log "Caddy: маршрут /harness/* уже есть — пропускаю."
    return
  fi
  local backup anchor
  backup="$CADDYFILE.bak.$(date +%s)"
  cp "$CADDYFILE" "$backup"

  # Встаём рядом с /gw/ (наш ближайший сосед), иначе перед любым handle.
  anchor="$(grep -n 'handle /gw/\*' "$CADDYFILE" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || anchor="$(grep -n 'handle /lab/\*' "$CADDYFILE" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || anchor="$(grep -n '^[[:space:]]*handle' "$CADDYFILE" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || die "Не нашёл блок handle в $CADDYFILE — добавь маршрут вручную (Caddyfile.snippet). Бэкап: $backup"

  log "Caddy: вставляю handle /harness/* → 127.0.0.1:$HARNESS_PORT (перед строкой $anchor)"
  awk -v line="$anchor" -v port="$HARNESS_PORT" 'NR==line{
    print "    handle /harness/* {"
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

# ── 6. Смоук-проверки: наш сервис + регрессия соседей ────────────────────────
sleep 5
log "Смоук: локальный /harness/health"
curl -fsS --max-time 10 "http://127.0.0.1:$HARNESS_PORT/harness/health" && echo || die "Сервис не отвечает — смотри journalctl -u llm-harness"
log "Проверка связи с gateway"
curl -fsS --max-time 10 "http://127.0.0.1:3400/gw/health" >/dev/null 2>&1 && echo "  /gw OK" || echo "  ВНИМАНИЕ: gateway /gw/health не ответил — harness без него не работает!"
log "Регрессия соседей (не должны сломаться)"
curl -fsS --max-time 10 "http://127.0.0.1:3300/lab/health"     >/dev/null 2>&1 && echo "  /lab OK"     || echo "  ВНИМАНИЕ: /lab не ответил"
curl -fsS --max-time 10 "http://127.0.0.1:3200/support/health" >/dev/null 2>&1 && echo "  /support OK" || echo "  ВНИМАНИЕ: /support не ответил"
curl -fsS --max-time 10 "http://127.0.0.1:3100/agent/health"   >/dev/null 2>&1 && echo "  /agent OK"   || echo "  ВНИМАНИЕ: /agent не ответил"
log "Статус сервиса:"
systemctl --no-pager --lines=5 status llm-harness || true
log "Готово. Открой /harness/ — запускай прогоны; /harness/admin — токен из вывода выше."
