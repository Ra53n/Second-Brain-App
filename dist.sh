#!/bin/bash
# dist.sh — дистрибутив Second Brain: сборка + подпись + DMG/zip (задача 18).
#
# Две ветки подписи, выбираются автоматически:
#  А. В Keychain есть сертификат «Developer ID Application» (или задан env
#     DIST_IDENTITY) → подпись Developer ID + hardened runtime + нотаризация
#     (профиль notarytool в Keychain, env NOTARY_PROFILE, дефолт
#     second-brain-notary; создать: xcrun notarytool store-credentials) +
#     stapler. Приложение запускается на чужом Mac без плясок.
#  Б. Сертификата нет → ad-hoc подпись. На другом Mac потребуется снять
#     карантин (инструкция — INSTALL.md).
#
# Архитектура: только arm64 — все Mac пользователя на Apple Silicon, а
# WhisperKit (CoreML) и Ollama целятся именно в него; universal-сборка
# удвоила бы размер без пользы. Решение зафиксировано в INSTALL.md.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SecondBrain"
APP_DIR="${APP_NAME}.app"
DIST_DIR="dist"
ENTITLEMENTS="SecondBrain.entitlements"

# --- Версия из git-тега: v1.2 → 1.2; без тега — короткий хеш коммита ---
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
VERSION="${VERSION#v}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▶ Версия: ${VERSION} (сборка ${BUILD_NUMBER}), arm64"
APP_VERSION="${VERSION}" APP_BUILD="${BUILD_NUMBER}" bash run.sh

# --- Выбор подписи ---
IDENTITY="${DIST_IDENTITY:-}"
if [ -z "${IDENTITY}" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
fi

if [ -n "${IDENTITY}" ]; then
    echo "▶ Ветка А: подпись Developer ID — ${IDENTITY}"
    SIGN_ARGS=(--sign "${IDENTITY}")
else
    echo "▶ Ветка Б: ad-hoc подпись (Developer ID в Keychain не найден)."
    SIGN_ARGS=(--sign -)
fi

# Hardened runtime в обеих ветках: поведение подписанной сборки (в т.ч.
# работоспособность микрофона и дочерних процессов) проверяется одинаково.
codesign --force --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    "${SIGN_ARGS[@]}" "${APP_DIR}"

echo "▶ Проверка подписи…"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
if [ -n "${IDENTITY}" ]; then
    : # spctl проверим после нотаризации
else
    echo "  (spctl для ad-hoc ожидаемо ругается на источник — это норма ветки Б):"
    spctl -a -t exec -vv "${APP_DIR}" 2>&1 | sed 's/^/    /' || true
fi

mkdir -p "${DIST_DIR}"

# --- Нотаризация (только ветка А) ---
if [ -n "${IDENTITY}" ]; then
    PROFILE="${NOTARY_PROFILE:-second-brain-notary}"
    NOTARY_ZIP="$(mktemp -d)/${APP_NAME}.zip"
    ditto -c -k --keepParent "${APP_DIR}" "${NOTARY_ZIP}"
    echo "▶ Нотаризация (Keychain-профиль «${PROFILE}»)…"
    if xcrun notarytool submit "${NOTARY_ZIP}" --keychain-profile "${PROFILE}" --wait; then
        xcrun stapler staple "${APP_DIR}"
        echo "▶ Gatekeeper:"
        spctl -a -t exec -vv "${APP_DIR}"
    else
        echo "⚠ Нотаризация не прошла. Создайте профиль:"
        echo "    xcrun notarytool store-credentials ${PROFILE} --apple-id <id> --team-id <team>"
        echo "  Артефакты будут собраны БЕЗ нотаризации."
    fi
    rm -rf "$(dirname "${NOTARY_ZIP}")"
fi

# --- Упаковка: DMG (симлинк на /Applications) + zip (ditto сохраняет подпись) ---
STAGING="$(mktemp -d)"
cp -R "${APP_DIR}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
DMG="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
rm -f "${DMG}"
echo "▶ DMG: ${DMG}"
hdiutil create -volname "Second Brain" -srcfolder "${STAGING}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGING}"

ZIP="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"
rm -f "${ZIP}"
echo "▶ ZIP: ${ZIP}"
ditto -c -k --keepParent "${APP_DIR}" "${ZIP}"

echo "✅ Готово:"
ls -lh "${DMG}" "${ZIP}" | awk '{print "   " $9 " (" $5 ")"}'
echo "   Установка на другом Mac — см. INSTALL.md."
