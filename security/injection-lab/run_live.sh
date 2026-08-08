#!/usr/bin/env bash
# Живой прогон лаборатории инъекций против настоящего DeepSeek (домашка «День 12»).
# 1) регенерирует lab_dump.json реальным кодом приложения (тест InjectionLabDumpTests);
# 2) запускает live_probe.py — полный tool-use цикл против DeepSeek по 3 векторам.
#
# Дамп собирается тем же ChatPromptBuilder / RagSearchTool / ReadFileTool, что и
# приложение, поэтому прогон проверяет реальную сборку, а не её пересказ.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DUMP="$(dirname "$0")/lab_dump.json"

echo "[1/2] Генерация дампа реальным кодом приложения…"
INJECTION_LAB_DUMP="$DUMP" "$REPO/scripts/test.sh" --filter InjectionLabDumpTests >/dev/null
echo "      дамп: $DUMP"

echo "[2/2] Живой прогон против DeepSeek…"
python3 "$(dirname "$0")/live_probe.py" --dump "$DUMP" "$@"
