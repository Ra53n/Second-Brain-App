#!/usr/bin/env bash
# smoke-all.sh — цикл прогона по импакту: diff → тесты+смоук → единый отчёт (задача 60).
#
# Использование:
#   ./scripts/smoke-all.sh [base-ref] [--full] [--dry-run] [--out <dir>] [--changed "<пути>"]
#     base-ref  — git-ref для diff (умолчание: main; если HEAD уже main → HEAD~1)
#     --full    — форсировать полный прогон: все сценарии + весь test.sh без фильтра
#     --dry-run — только показать выбор (режим/сценарии/фильтр), ничего не гонять
#     --out     — каталог для HTML-отчётов (умолчание: smoke/out/, создаётся сам)
#     --changed — свой список путей вместо git diff (для проверки --dry-run без реального дифа)
#
# Опирается на impact-map.tsv (диф → раздел/сценарий/фильтр), scripts/test.sh --filter
# и scripts/ui.sh run --html (задачи 58/59). Смоук — только read-only check-сценарии.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAP_FILE="$ROOT/smoke/impact-map.tsv"

usage() { sed -n '2,14p' "$0"; }

# ---------- аргументы ----------

BASE_REF=""
FORCE_FULL=0
DRY_RUN=0
OUT_DIR=""
CHANGED_SET=0
CHANGED_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --full)    FORCE_FULL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --out)     OUT_DIR="${2:?нужен путь после --out}"; shift 2 ;;
    --changed) CHANGED_SET=1; CHANGED_OVERRIDE="${2:?нужен список путей после --changed}"; shift 2 ;;
    --*)       echo "неизвестный флаг: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [ -z "$BASE_REF" ]; then BASE_REF="$1"; else echo "лишний аргумент: $1" >&2; exit 1; fi
      shift ;;
  esac
done

[ -z "$BASE_REF" ] && BASE_REF="main"
if [ "$BASE_REF" = "main" ]; then
  head_branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$head_branch" = "main" ] && BASE_REF="HEAD~1"
fi

# ---------- карта импакта: чтение и обратный поиск ----------

# relpath (без Sources/SecondBrain/) → "раздел\tсценарий\tфильтр"; код 1 — не покрыт картой.
match_file() {
  local relpath="$1" glob section scenario filt prefix
  while IFS=$'\t' read -r glob section scenario filt; do
    [ -z "$glob" ] && continue
    case "$glob" in "#"*) continue ;; esac
    prefix="${glob%/\*\*}/"
    case "$relpath" in
      "$prefix"*) printf '%s\t%s\t%s\n' "$section" "$scenario" "$filt"; return 0 ;;
    esac
  done < "$MAP_FILE"
  return 1
}

all_scenarios() {
  local glob section scenario filt
  while IFS=$'\t' read -r glob section scenario filt; do
    [ -z "$glob" ] && continue
    case "$glob" in "#"*) continue ;; esac
    [ "$scenario" = "*" ] && continue
    echo "$scenario"
  done < "$MAP_FILE" | sort -u
}

section_for_scenario() {
  local target="$1" glob section scenario filt
  while IFS=$'\t' read -r glob section scenario filt; do
    [ -z "$glob" ] && continue
    case "$glob" in "#"*) continue ;; esac
    [ "$(basename "$scenario" 2>/dev/null)" = "$target" ] && { echo "$section"; return 0; }
  done < "$MAP_FILE"
  return 1
}

# Обратная карта локализации: все module_glob, чей раздел совпадает с упавшим.
modules_for_section() {
  local target="$1" glob section scenario filt out=""
  while IFS=$'\t' read -r glob section scenario filt; do
    [ -z "$glob" ] && continue
    case "$glob" in "#"*) continue ;; esac
    [ "$section" = "$target" ] && out="$out $glob"
  done < "$MAP_FILE"
  printf '%s' "${out# }"
}

# ---------- чистое ядро: diff → режим + сценарии + фильтр ----------

# stdin — относительные пути (Sources/SecondBrain/ уже срезан), по одному на строку.
# Пустой ввод при FORCE_FULL=0 сюда не попадает — перехвачен раньше вызова.
# Печатает 3 строки: mode(full|selective) / сценарии через пробел / фильтр (regex или пусто).
compute_selection() {
  local relpath match sect scen filt full=0 scenarios="" filters=""
  [ "$FORCE_FULL" -eq 1 ] && full=1
  while IFS= read -r relpath; do
    [ -z "$relpath" ] && continue
    if match="$(match_file "$relpath")"; then
      IFS=$'\t' read -r sect scen filt <<< "$match"
      if [ "$scen" = "*" ]; then
        full=1
      else
        scenarios="$scenarios
$scen"
        filters="$filters
$filt"
      fi
    else
      full=1   # путь под Sources/**, но карта его не покрывает — расширяем до полного
    fi
  done

  # Значение сначала в переменную, потом явный echo: хвост пайплайна (tr/sed) не
  # гарантирует финальный \n, а без него следующая строка отчёта склеится с этой.
  if [ "$full" -eq 1 ]; then
    local all
    all="$(all_scenarios | tr '\n' ' ' | sed -e 's/^ *//' -e 's/ *$//')"
    echo full
    echo "$all"
    echo ""
    return 0
  fi

  local scen_joined filt_joined
  scen_joined="$(printf '%s\n' "$scenarios" | sed '/^$/d' | sort -u | tr '\n' ' ' | sed -e 's/^ *//' -e 's/ *$//')"
  filt_joined="$(printf '%s\n' "$filters" | sed '/^$/d' | sort -u | tr '\n' '|' | sed 's/|$//')"
  echo selective
  echo "$scen_joined"
  echo "$filt_joined"
}

mode_ru() { [ "$1" = full ] && echo "полный" || echo "выборочный"; }

# ---------- сбор изменённых файлов ----------

gather_changed() {
  if [ "$CHANGED_SET" -eq 1 ]; then
    printf '%s' "$CHANGED_OVERRIDE" | tr -s ' \t\n' '\n' | sed '/^$/d'
    return 0
  fi
  { git -C "$ROOT" diff --name-only "$BASE_REF"
    git -C "$ROOT" diff --name-only
  } 2>/dev/null | sort -u
}

changed_src="$(gather_changed | grep '^Sources/SecondBrain/' 2>/dev/null | sed 's#^Sources/SecondBrain/##' | sort -u)"
changed_count="$(printf '%s\n' "$changed_src" | sed '/^$/d' | grep -c .)"

if [ "$changed_count" -eq 0 ] && [ "$FORCE_FULL" -eq 0 ]; then
  echo "нет изменений в коде — смоук не требуется"
  exit 0
fi

selection="$(printf '%s\n' "$changed_src" | compute_selection)"
mode="$(printf '%s\n' "$selection" | sed -n '1p')"
scen_list="$(printf '%s\n' "$selection" | sed -n '2p')"
filter="$(printf '%s\n' "$selection" | sed -n '3p')"

# ---------- --dry-run: только выбор, ничего не гоняем ----------

if [ "$DRY_RUN" -eq 1 ]; then
  echo "ИЗМЕНЕНО: $changed_count файл(ов) в Sources/SecondBrain"
  echo "РЕЖИМ: $(mode_ru "$mode")"
  echo "СЦЕНАРИИ: $scen_list"
  if [ "$mode" = full ]; then
    echo "ТЕСТ-ФИЛЬТР: (без фильтра — весь набор)"
  else
    echo "ТЕСТ-ФИЛЬТР: $filter"
    echo "ВЕРОЯТНЫЕ МОДУЛИ (если раздел упадёт):"
    for scen in $scen_list; do
      name="$(basename "$scen")"
      sect="$(section_for_scenario "$name")"
      echo "  $name (раздел «$sect»): $(modules_for_section "$sect")"
    done
  fi
  exit 0
fi

# ---------- оркестратор: реальный прогон ----------

OUT_DIR="${OUT_DIR:-$ROOT/smoke/out}"
mkdir -p "$OUT_DIR"

echo "ИЗМЕНЕНО: $changed_count файл(ов) в Sources/SecondBrain"
echo "РЕЖИМ: $(mode_ru "$mode")"
echo "СЦЕНАРИИ: $scen_list"
echo

echo "--- Тесты ---"
if [ "$mode" = full ]; then
  tests_out="$("$ROOT/scripts/test.sh" 2>&1)"; tests_code=$?
else
  tests_out="$("$ROOT/scripts/test.sh" --filter "$filter" 2>&1)"; tests_code=$?
fi
echo "$tests_out"
echo

echo "--- Смоук ---"
preflight_out="$("$ROOT/scripts/ui.sh" preflight 2>&1)"; preflight_code=$?
echo "$preflight_out"

smoke_skipped=0
failed_scenarios=""
if [ "$preflight_code" -ne 0 ]; then
  echo "WARN  смоук пропущен: несвежая сборка или приложение не запущено — ./install.sh"
  smoke_skipped=1
else
  for scen in $scen_list; do
    name="$(basename "$scen" .txt)"
    scen_out="$("$ROOT/scripts/ui.sh" run "$ROOT/$scen" --html "$OUT_DIR/$name.html" 2>&1)"; scen_code=$?
    echo "$scen_out"
    [ "$scen_code" -ne 0 ] && failed_scenarios="$failed_scenarios $name"
  done
fi

echo
echo "--- ИТОГ ---"
if [ "$tests_code" -eq 0 ]; then echo "Тесты: OK"; else echo "Тесты: ПРОВАЛ (код $tests_code)"; fi
if [ "$smoke_skipped" -eq 1 ]; then
  echo "Смоук: ПРОПУЩЕН"
elif [ -n "$failed_scenarios" ]; then
  echo "Смоук: ПРОВАЛ —$failed_scenarios"
else
  echo "Смоук: OK"
fi

overall=0
[ "$tests_code" -ne 0 ] && overall=1
[ -n "$failed_scenarios" ] && overall=1
[ "$smoke_skipped" -eq 1 ] && overall=1

if [ "$overall" -ne 0 ]; then
  echo
  echo "--- ГДЕ СМОТРЕТЬ ---"
  [ "$tests_code" -ne 0 ] && echo "Тесты: упавший тест назван выше в блоке «Тесты» (test.sh печатает его сам)."
  for name in $failed_scenarios; do
    sect="$(section_for_scenario "$name.txt")"
    echo "Сценарий $name.txt (раздел «$sect»): вероятные модули — $(modules_for_section "$sect")"
  done
fi

exit $overall
