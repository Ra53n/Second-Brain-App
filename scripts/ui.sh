#!/usr/bin/env bash
# ui.sh — смоук UI SecondBrain через Accessibility с таймаутом (задача 49).
#
# Зачем: скриншоты окна не работают (kCGWindowSharingState = 0), а голый osascript
# виснет навсегда, если приложение показало модалку или система спросила права
# Automation. Здесь каждый AX-вызов ограничен таймаутом, а вывод компактный:
# ассерт вместо дампа дерева.
#
# Использование:
#   ./scripts/ui.sh preflight              состояние: процесс, окно, свежесть сборки
#   ./scripts/ui.sh open Встречи           открыть раздел (с проверкой, что открылся)
#   ./scripts/ui.sh restart                перезапустить приложение (лекарство от залипания)
#   ./scripts/ui.sh check "Транскрипция"   PASS/FAIL одной строкой
#   ./scripts/ui.sh click "Настройки"      нажать элемент по подстроке подписи
#   ./scripts/ui.sh list                   интерактивные элементы экрана (компактно)
#   ./scripts/ui.sh dump                   всё дерево (дорого, для разбора)
#   ./scripts/ui.sh run smoke/meetings.txt прогон сценария, один компактный отчёт
#
# Переменные: UI_TIMEOUT (сек, по умолчанию 15), SMOKE_ALLOW_DESTRUCTIVE=1 —
# разрешить нажатия из запретного списка (только на тестовом vault!).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AX="$ROOT/scripts/ax.applescript"
APP="/Applications/SecondBrain.app"
TIMEOUT="${UI_TIMEOUT:-15}"

# Кнопки с необратимыми или дорогими побочными эффектами: запись встречи, удаление,
# git-операции, индексация (тратит эмбеддинги), отправка в LLM. На живом vault
# агент их не жмёт; на тестовом — SMOKE_ALLOW_DESTRUCTIVE=1.
DESTRUCTIVE='Записать|Запись|Удалить|Удаление|Push|Отправить|Коммит|Commit|Индексировать|Переиндекс|Перестроить|Синхронизац|Откатить'

# Окно приложения могло быть закрыто пользователем или предыдущим прогоном:
# без него System Events отдаёт -1719, и агент уходит в бесполезные ретраи.
ensure_window() {
  local n
  # Считать окна можно только у активного приложения: в фоне их «ноль».
  n=$(perl -e 'alarm 10; exec @ARGV' 10 osascript \
      -e 'tell application "SecondBrain" to activate' -e 'delay 0.4' \
      -e 'tell application "System Events" to tell process "SecondBrain" to return count of windows' 2>/dev/null | tail -1)
  if [ "${n:-0}" = "0" ]; then
    open -a "$APP" 2>/dev/null
    sleep 2
  fi
}

# Запуск osascript с жёстким таймаутом: SIGALRM убивает зависший вызов.
osa() {
  local out code
  ensure_window
  out=$(perl -e 'alarm shift @ARGV; exec @ARGV' "$TIMEOUT" osascript "$AX" "$@" 2>&1)
  code=$?
  if [ $code -eq 142 ] || [ $code -eq 14 ]; then
    echo "ТАЙМАУТ ${TIMEOUT}с — вероятно, на экране модалка или запрос прав Automation."
    return 2
  fi
  echo "$out"
  [[ "$out" == FAIL* ]] && return 1
  [[ "$out" == *"execution error"* ]] && return 1
  return 0
}

cmd_preflight() {
  local ok=0
  if pgrep -qf "SecondBrain.app/Contents/MacOS/SecondBrain"; then
    echo "OK    процесс запущен"
  else
    echo "FAIL  приложение не запущено: open -a $APP"; ok=1
  fi
  if [ -d "$APP" ]; then
    local app_mtime src_mtime
    app_mtime=$(stat -f %m "$APP/Contents/MacOS/SecondBrain" 2>/dev/null || echo 0)
    src_mtime=$(find "$ROOT/Sources" -name '*.swift' -exec stat -f %m {} + 2>/dev/null | sort -rn | head -1)
    if [ "$app_mtime" -lt "${src_mtime:-0}" ]; then
      echo "FAIL  установленная сборка старше исходников: ./install.sh"; ok=1
    else
      echo "OK    сборка свежая"
    fi
  else
    echo "FAIL  $APP не установлен: ./install.sh"; ok=1
  fi
  osa window || ok=1
  return $ok
}

cmd_run() {
  local file="$1" pass=0 fail=0 line action arg
  [ -f "$file" ] || { echo "FAIL  сценарий не найден: $file"; return 1; }
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    action="${line%% *}"; arg="${line#* }"
    case "$action" in
      open)  out=$(cmd_open "$arg" | grep -E "^(OK|FAIL)" | tail -1) ;;
      click) out=$(cmd_click "$arg") ;;
      check) out=$(osa check "$arg") ;;
      *)     out="FAIL  неизвестный шаг: $line" ;;
    esac
    echo "$out"
    [[ "$out" == FAIL* || "$out" == ТАЙМАУТ* ]] && fail=$((fail+1)) || pass=$((pass+1))
    [[ "$out" == ТАЙМАУТ* ]] && break
  done < "$file"
  echo "ИТОГ: $pass пройдено, $fail провалено — $file"
  [ $fail -eq 0 ]
}

# Маркер, по которому видно, что раздел действительно открылся. Клик по строке
# сайдбара AX иногда принимается и молча игнорируется SwiftUI — «OK» без проверки
# врёт, поэтому open всегда подтверждает результат.
section_marker() {
  case "$1" in
    Заметки)   echo "Новая заметка" ;;
    Встречи)   echo "Транскрипция" ;;
    Чат)       echo "Инструменты" ;;
    Пайплайны) echo "Пайплайн" ;;
    Настройки) echo "Настройки" ;;
    *)         echo "" ;;
  esac
}

cmd_restart() {
  osascript -e 'tell application "SecondBrain" to quit' >/dev/null 2>&1
  sleep 3
  open -a "$APP" >/dev/null 2>&1
  sleep 4
  echo "OK    приложение перезапущено"
}

# Слаг раздела для ссылки secondbrain://section/<slug> (задача 50).
section_slug() {
  case "$1" in
    Заметки) echo notes ;; Встречи) echo meetings ;; Чат) echo chat ;;
    Пайплайны) echo pipelines ;; Настройки) echo settings ;; *) echo "" ;;
  esac
}

cmd_open() {
  local section="$1" marker attempt out slug
  marker="$(section_marker "$section")"
  slug="$(section_slug "$section")"
  for attempt in 1 2; do
    # Основной путь — deep link: детерминирован, в отличие от AX-клика по
    # сайдбару (см. «Результат» задачи 49). AX остаётся фолбэком для сборок
    # без URL-схемы.
    if [ -n "$slug" ]; then
      open "secondbrain://section/$slug" 2>/dev/null
      sleep 1
      if [ -n "$marker" ] && [[ "$(osa check "$marker")" == PASS* ]]; then
        echo "OK    открыт раздел: $section (deep link)"; return 0
      fi
    fi
    osa click "$section" >/dev/null
    if [ -z "$marker" ]; then echo "OK    открыт раздел: $section (маркер не задан)"; return 0; fi
    out=$(osa check "$marker")
    if [[ "$out" == PASS* ]]; then echo "OK    открыт раздел: $section"; return 0; fi
    [ $attempt -eq 1 ] && { echo "…клик принят, но раздел не сменился — перезапуск приложения"; cmd_restart >/dev/null; }
  done
  echo "FAIL  раздел не открылся: $section — приложение игнорирует AX-клики."
  echo "      Проверь вручную; в отчёте пиши «навигация недоступна», не зацикливайся."
  return 1
}

cmd_click() {
  local target="$1"
  if [[ "${SMOKE_ALLOW_DESTRUCTIVE:-0}" != "1" ]] && [[ "$target" =~ $DESTRUCTIVE ]]; then
    echo "SKIP  клик: $target — побочный эффект; на тестовом vault: SMOKE_ALLOW_DESTRUCTIVE=1"
    return 0
  fi
  osa click "$target"
}

case "${1:-}" in
  preflight) cmd_preflight ;;
  open)      cmd_open "${2:?раздел}" ;;
  restart)   cmd_restart ;;
  check)     osa check "${2:?текст}" ;;
  click)     cmd_click "${2:?текст}" ;;
  list)      osa list ;;
  dump)      osa dump ;;
  window)    osa window ;;
  run)       cmd_run "${2:?файл сценария}" ;;
  *) sed -n '2,25p' "$0"; exit 1 ;;
esac
