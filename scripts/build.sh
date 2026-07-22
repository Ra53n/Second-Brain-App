#!/usr/bin/env bash
# build.sh — тихая сборка: только ошибки, уникальные варнинги и итог (задача 48).
#
# swift build дублирует один и тот же варнинг на каждый модуль компиляции;
# здесь они схлопываются, а «Compiling …» не печатается вовсе.
#
# Использование:  ./scripts/build.sh  [-c release]  (аргументы уходят в swift build)

set -uo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

out=$(swift build "$@" 2>&1)
code=$?

echo "$out" | grep -E "error:" | sort -u | head -30
echo "$out" | grep -E "warning:" | sed 's/^.*Sources/Sources/' | sort -u | head -15
echo "$out" | grep -E "Build complete|Compiling|error: " | tail -1

exit $code
