#!/usr/bin/env bash
# capture.sh — захват результата одной генерации бенчмарка (задача 51).
#
# Складывает в bench/out/ три артефакта:
#   <label>.patch       — полный дифф от базы (коммиты + незакоммиченное)
#   <label>.html        — self-contained рендер диффа для скриншота
#   <label>-stats.txt   — статистика: файлы, строки, тесты, коммиты
#
# Использование:
#   ./bench/capture.sh gen1              # база — тег bench-base
#   ./bench/capture.sh gen2 bench-base-v2
#
# После захвата — откат: git reset --hard <база> && git clean -fd

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:?нужна метка генерации, например gen1}"
BASE="${2:-bench-base}"
OUT="$ROOT/bench/out"

cd "$ROOT" || exit 1

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "FAIL  база '$BASE' не найдена. Поставь тег: git tag $BASE"
  exit 1
fi

mkdir -p "$OUT"

# Дифф от базы до рабочего дерева: HEAD может быть и с коммитами, и без —
# так захватывается работа независимо от того, закоммитил её агент или нет.
git add -AN >/dev/null 2>&1            # чтобы новые файлы попали в дифф
git diff "$BASE" > "$OUT/$LABEL.patch"

{
  echo "Генерация: $LABEL"
  echo "База:      $BASE ($(git rev-parse --short "$BASE"))"
  echo "HEAD:      $(git rev-parse --short HEAD)"
  echo
  echo "== Коммиты поверх базы =="
  git log --oneline "$BASE..HEAD" 2>/dev/null || echo "(нет)"
  echo
  echo "== Файлы =="
  git diff --stat "$BASE"
  echo
  echo "== Сводка =="
  printf "файлов изменено: %s\n" "$(git diff --name-only "$BASE" | wc -l | tr -d ' ')"
  printf "строк добавлено: %s\n" "$(git diff --numstat "$BASE" | awk '{s+=$1} END {print s+0}')"
  printf "строк удалено:   %s\n" "$(git diff --numstat "$BASE" | awk '{s+=$2} END {print s+0}')"
  printf "файлов тестов:   %s\n" "$(git diff --name-only "$BASE" | grep -c 'Tests/.*\.swift' || true)"
  printf "файлов задач:    %s\n" "$(git diff --name-only "$BASE" | grep -c '^tasks/' || true)"
} > "$OUT/$LABEL-stats.txt"

python3 "$ROOT/bench/render_diff.py" "$OUT/$LABEL.patch" "$OUT/$LABEL.html" "$LABEL" || {
  echo "WARN  не удалось отрендерить HTML (патч и статистика сохранены)"
}

cat "$OUT/$LABEL-stats.txt"
echo
echo "OK    $OUT/$LABEL.patch, $LABEL.html, $LABEL-stats.txt"
echo "      откат: git reset --hard $BASE && git clean -fd"
