#!/usr/bin/env bash
# run.sh — прогон домашки Дня 14: 3 задачи через LLM Gateway + сводка.
# Использование: GW_URL=https://<VPS_HOST>/gw [GW_ADMIN_TOKEN=…] ./run.sh [id-задачи]
set -euo pipefail
cd "$(dirname "$0")"
: "${GW_URL:?задай GW_URL, пример: https://<VPS_HOST>/gw}"

python3 loop.py "$@"
python3 report.py
