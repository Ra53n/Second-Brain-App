#!/bin/bash
# Собирает release-бинарь и упаковывает его в SecondBrain.app,
# чтобы приложение запускалось как обычное Mac-приложение (с окном и в Dock).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="SecondBrain"
APP_DIR="${APP_NAME}.app"
BIN_NAME="SecondBrain"

# Версия приложения: dist.sh подставляет значение из git-тега; при ручном
# запуске run.sh остаётся дефолт для разработки.
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD="${APP_BUILD:-1}"

# Если лицензия Xcode не принята (`sudo xcodebuild -license accept`),
# можно собрать тулчейном Command Line Tools, раскомментировав строку:
# export DEVELOPER_DIR=/Library/Developer/CommandLineTools

echo "▶ Сборка (release)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${BIN_NAME}"

echo "▶ Упаковка в ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${BIN_NAME}"

# Ресурсный бандл SPM (внутри — AppIcon.icns для Bundle.module).
BUNDLE_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "${BUNDLE_PATH}" ]; then
    cp -R "${BUNDLE_PATH}" "${APP_DIR}/Contents/Resources/"
    # SPM не кладёт в ресурсный бандл Info.plist — без него CFBundle
    # (Bundle.module.url) ВИСНЕТ при первом обращении, и приложение не
    # открывает окно (проявляется на упакованном .app). Пишем минимальный.
    RES_BUNDLE="${APP_DIR}/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle"
    if [ ! -f "${RES_BUNDLE}/Info.plist" ]; then
        cat > "${RES_BUNDLE}/Info.plist" <<BPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.local.second-brain.resources</string>
    <key>CFBundleName</key><string>${APP_NAME}_${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
</dict></plist>
BPLIST
    fi
fi

# Иконка приложения (если собрана).
ICON_SRC="Sources/SecondBrain/Resources/AppIcon.icns"
if [ -f "${ICON_SRC}" ]; then
    cp "${ICON_SRC}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

# NSMicrophoneUsageDescription / NSAudioCaptureUsageDescription — без этих
# ключей в Info.plist macOS молча убивает приложение при обращении к микрофону
# или системному звуку (Core Audio process tap, задача 06).
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Second Brain</string>
    <key>CFBundleDisplayName</key>
    <string>Second Brain</string>
    <key>CFBundleExecutable</key>
    <string>${BIN_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.second-brain</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Second Brain записывает встречи с микрофона для последующей транскрипции.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Second Brain записывает системный звук (голоса собеседников в Zoom/Meet) для транскрипции встреч.</string>
</dict>
</plist>
PLIST

# --- Подпись стабильной личностью (задача 39, фикс повторных запросов) ---
# Без явной подписи бинарь получает ad-hoc подпись линкера, которая меняется
# каждой сборкой — macOS считает приложение НОВЫМ и заново спрашивает и
# Keychain (ключи API), и TCC (Рабочий стол/Документы). Стабильный сертификат
# («Second Brain Dev», self-signed, см. tasks/39-file-tools.md, или Developer
# ID) делает designated requirement постоянным — разрешения выдаются один раз.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "${IDENTITY}" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"(Second Brain Dev|Developer ID Application: [^"]*)"' \
        | head -1 | tr -d '"' || true)"
fi
if [ -n "${IDENTITY}" ]; then
    echo "▶ Подпись: ${IDENTITY}"
    codesign --force --sign "${IDENTITY}" "${APP_DIR}"
else
    echo "⚠ Сертификат «Second Brain Dev» не найден — ad-hoc подпись:"
    echo "  macOS будет заново спрашивать разрешения после каждой пересборки."
    echo "  Одноразовая настройка — см. «Результат» в tasks/39-file-tools.md."
fi

echo "✅ Готово: ${APP_DIR}"
echo "   Запуск:  open \"${APP_DIR}\""
