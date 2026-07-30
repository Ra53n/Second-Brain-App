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
#   ./scripts/ui.sh run smoke/meetings.txt --html out.html   + самодостаточный HTML (задача 59)
#   ./scripts/ui.sh run smoke/meetings.txt --tsv out.tsv [--dump-to out.dump]   без HTML,
#                                           для сборки сводного отчёта smoke-all.sh (задача 61)
#   ./scripts/ui.sh windows                число окон процесса (проверка «окна не плодятся»)
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
DESTRUCTIVE='Записать|Запись|Удалить|Удаление|Push|Отправить|Коммит|Commit|Индексировать|Переиндекс|Перестроить|Синхронизац|Откатить|Запустить тюн'

# Окно приложения могло быть закрыто пользователем или предыдущим прогоном:
# без него System Events отдаёт -1719, и агент уходит в бесполезные ретраи.
# `open -a` при уже живом процессе с открытым окном НЕ плодит окна (проверено
# эмпирически) — плодит их deep-link `open secondbrain://…` в cmd_open (см.
# close_extra_windows ниже). Здесь `open -a` — только для двух случаев: процесс
# мёртв или у живого процесса ноль окон; иначе — просто activate.
ensure_window() {
  local n
  if ! pgrep -qf "SecondBrain.app/Contents/MacOS/SecondBrain"; then
    open -a "$APP" 2>/dev/null
    sleep 2
    return
  fi
  # Считать окна можно только у активного приложения: в фоне их «ноль».
  n=$(perl -e 'alarm shift @ARGV; exec @ARGV' 10 osascript \
      -e 'tell application "SecondBrain" to activate' -e 'delay 0.4' \
      -e 'tell application "System Events" to tell process "SecondBrain" to return count of windows' 2>/dev/null | tail -1)
  if [ "${n:-0}" = "0" ]; then
    open -a "$APP" 2>/dev/null
    sleep 2
  fi
}

# Печатает число окон процесса (0, если процесс не запущен) — способ убедиться,
# что прогон не плодит окна.
cmd_windows() {
  if ! pgrep -qf "SecondBrain.app/Contents/MacOS/SecondBrain"; then
    echo 0
    return 0
  fi
  perl -e 'alarm shift @ARGV; exec @ARGV' 10 osascript \
      -e 'tell application "SecondBrain" to activate' -e 'delay 0.3' \
      -e 'tell application "System Events" to tell process "SecondBrain" to return count of windows' 2>/dev/null | tail -1
}

# Deep-link `open secondbrain://…` (cmd_open) создаёт НОВОЕ окно на каждый
# вызов, даже для того же раздела, даже когда приложение уже на переднем плане
# (подтверждено эмпирически) — это поведение SwiftUI-сцены, лечится не здесь
# (Sources/ вне объёма задачи 61). Единственное окно после навигации —
# фронтовое (только что открытое); закрываем более старые следом.
close_extra_windows() {
  perl -e 'alarm shift @ARGV; exec @ARGV' 10 osascript -e '
    tell application "SecondBrain" to activate
    delay 0.2
    tell application "System Events" to tell process "SecondBrain"
      repeat while (count of windows) > 1
        set nwin to count of windows
        try
          click (first button of window nwin whose subrole is "AXCloseButton")
        on error
          exit repeat
        end try
        delay 0.3
      end repeat
    end tell' >/dev/null 2>&1
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
  local file="${1:?файл сценария}" pass=0 fail=0 line action arg out status
  local html_out="" tsv_out="" dump_out="" steps_tsv="" dump_file="" dump_taken=0
  local need_capture=0 need_dump=0 tmp_steps=0 tmp_dump=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --html)    html_out="${2:?путь для HTML}"; shift 2 ;;
      --tsv)     tsv_out="${2:?путь для TSV}"; shift 2 ;;
      --dump-to) dump_out="${2:?путь для дампа}"; shift 2 ;;
      *) echo "FAIL  неизвестный флаг: $1"; return 1 ;;
    esac
  done
  [ -f "$file" ] || { echo "FAIL  сценарий не найден: $file"; return 1; }

  # --tsv/--dump-to (задача 61): те же шаги без генерации HTML — smoke-all.sh
  # собирает TSV всех сценариев и зовёт smoke_report.py один раз на весь прогон.
  if [ -n "$html_out" ] || [ -n "$tsv_out" ]; then
    need_capture=1
    if [ -n "$tsv_out" ]; then steps_tsv="$tsv_out"; else steps_tsv=$(mktemp); tmp_steps=1; fi
    : > "$steps_tsv"
  fi
  if [ -n "$html_out" ] || [ -n "$dump_out" ]; then
    need_dump=1
    if [ -n "$dump_out" ]; then dump_file="$dump_out"; else dump_file=$(mktemp); tmp_dump=1; fi
  fi
  trap '[ "$tmp_steps" = 1 ] && rm -f "$steps_tsv"; [ "$tmp_dump" = 1 ] && rm -f "$dump_file"' RETURN

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

    if [[ "$out" == FAIL* || "$out" == ТАЙМАУТ* ]]; then
      status=FAIL; fail=$((fail+1))
    elif [[ "$out" == SKIP* ]]; then
      status=SKIP; pass=$((pass+1))
    else
      status=PASS; pass=$((pass+1))
    fi

    if [ "$need_capture" -eq 1 ]; then
      printf '%s\t%s\t%s\t%s\n' "$status" "$action" "$arg" "$out" >> "$steps_tsv"
      # Снимок только на первом сломанном шаге: дальше он один и тот же экран.
      if [ "$need_dump" -eq 1 ] && [ "$status" = "FAIL" ] && [ "$dump_taken" -eq 0 ]; then
        osa dump > "$dump_file" 2>&1
        dump_taken=1
      fi
    fi

    [[ "$out" == ТАЙМАУТ* ]] && break
  done < "$file"
  echo "ИТОГ: $pass пройдено, $fail провалено — $file"

  if [ -n "$html_out" ]; then
    # /bin/bash системный (3.2) — без массивов: пустой массив под set -u падает
    # «unbound variable», поэтому ветвим на дамп есть/нет явно.
    if [ "$dump_taken" -eq 1 ]; then
      python3 "$ROOT/scripts/smoke_report.py" --scenario "$(basename "$file")" \
        --steps "$steps_tsv" --out "$html_out" --dump "$dump_file"
    else
      python3 "$ROOT/scripts/smoke_report.py" --scenario "$(basename "$file")" \
        --steps "$steps_tsv" --out "$html_out"
    fi
    echo "HTML: $html_out"
  fi

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
    Тюнинг)    echo "Датасеты" ;;
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
    Пайплайны) echo pipelines ;; Тюнинг) echo finetune ;; Настройки) echo settings ;; *) echo "" ;;
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
      close_extra_windows
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
  windows)   cmd_windows ;;
  run)       shift; cmd_run "$@" ;;
  *) sed -n '2,21p' "$0"; exit 1 ;;
esac
