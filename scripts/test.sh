#!/usr/bin/env bash
# test.sh — тихий прогон тестов: только падения и итоговая строка (задача 48).
#
# swift test печатает две строки на каждый из 1000+ тестов — это десятки тысяч
# токенов в контексте агента при нулевой пользе. Здесь остаётся то, ради чего
# тесты и запускают: что упало и сколько прошло.
#
# Использование:  ./scripts/test.sh  [--filter ИмяКласса]  (аргументы уходят в swift test)

set -uo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

out=$(swift test "$@" 2>&1)
code=$?

# Ошибки компиляции и упавшие тесты — целиком, они нужны для разбора.
echo "$out" | grep -E "error:|: error|' failed|failed \(" | sort -u | head -40

# Итог: последняя сводка XCTest.
echo "$out" | grep -E "Executed [0-9]+ tests" | tail -1

if [ $code -ne 0 ]; then
  echo "ПРОГОН УПАЛ (код $code). Полный вывод: swift test"
fi
exit $code
