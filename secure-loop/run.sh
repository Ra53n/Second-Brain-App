#!/usr/bin/env bash
# run.sh — прогон execution loop Дня 14: все задачи или одна (t1-token|t2-logging|t3-api).
# Использование: GW_URL=https://<VPS_HOST>/gw ./run.sh [id-задачи]
set -euo pipefail
cd "$(dirname "$0")"
: "${GW_URL:?задай GW_URL, пример: https://<VPS_HOST>/gw}"

python3 loop.py "$@"
