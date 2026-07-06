#!/bin/bash
# Собирает приложение и устанавливает его в /Applications,
# чтобы оно было в Spotlight / Launchpad / Dock как обычная программа.
set -euo pipefail
cd "$(dirname "$0")"

echo "▶ Сборка и упаковка .app…"
bash run.sh

DEST="/Applications/SecondBrain.app"
echo "▶ Установка в ${DEST}…"
rm -rf "${DEST}"
cp -R "SecondBrain.app" "${DEST}"

# Снять карантин (на случай, если появится) и обновить Launch Services,
# чтобы иконка и Spotlight сразу подхватили приложение.
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${DEST}" 2>/dev/null || true

echo "✅ Установлено: ${DEST}"
echo "   Запуск: Spotlight (⌘Space → «Second Brain») или папка «Программы»."
