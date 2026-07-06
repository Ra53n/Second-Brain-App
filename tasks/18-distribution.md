# 18 — Дистрибуция

## Цель
Приложение, собранное на Mac владельца, запускается на любом другом Mac без плясок: подпись, упаковка в DMG/zip, понятная инструкция установки.

## Зависимости
01 (run.sh существует). Делать ближе к концу, когда есть что распространять.

## Контекст
Без подписи Gatekeeper на чужой машине заблокирует приложение («повреждено/неизвестный разработчик»). Два пути: (А) есть Apple Developer аккаунт ($99/год) — Developer ID подпись + нотаризация, идеальный UX; (Б) нет аккаунта — ad-hoc подпись + инструкция снятия quarantine. **Сначала спроси пользователя, есть ли у него Developer-аккаунт**, и реализуй соответствующую ветку (вторую — заготовкой в скрипте).

## Объём работ
- [ ] `dist.sh`: расширение run.sh —
  - сборка universal binary (`arch arm64 + x86_64` через `swift build --arch`), либо осознанно только arm64 (зафиксируй: все Mac пользователя — Apple Silicon?);
  - подпись: ветка А — `codesign --sign "Developer ID Application: ..."` с hardened runtime + entitlements (микрофон!), `notarytool submit --wait`, `stapler staple`; ветка Б — `codesign --sign -` (ad-hoc);
  - упаковка: DMG (`hdiutil` с симлинком на /Applications) или zip (`ditto -c -k --keepParent` — сохраняет подпись).
- [ ] Entitlements-файл: `com.apple.security.device.audio-input` + что потребуется (hardened runtime блокирует без явных entitlements); **проверь, что подписанное приложение по-прежнему может запускать дочерние процессы (Ollama, MCP-серверы) и JIT не нужен**.
- [ ] `INSTALL.md`: инструкция для «другого Mac» — обычная установка (ветка А) либо `xattr -dr com.apple.quarantine /Applications/SecondBrain.app` + правый клик→Открыть (ветка Б); плюс что доустановить (Ollama — опционально, git — есть в macOS с CLT).
- [ ] Версионирование: версия в Info.plist из git-тега (`git describe`), отображение в About.
- [ ] Обновить install.sh/README под новый скрипт.

## Вне объёма
Автообновления (Sparkle — бэклог 19), Mac App Store, CI.

## Критерии приёмки
- `./dist.sh` производит артефакт; `codesign --verify --deep --strict` и `spctl -a -t exec -vv` проходят (ветка А) / ожидаемо ругаются только на источник (ветка Б).
- Проверка на чистой машине или втором аккаунте macOS: приложение скачивается (симулируй quarantine: `xattr -w com.apple.quarantine ...`), устанавливается по INSTALL.md и запускается; микрофон и запуск Ollama работают в подписанной версии.
- В «Результате» — какая ветка реализована и почему.

## Подсказки
- Нотаризация требует App-Specific Password или App Store Connect API key — храни в Keychain (`notarytool store-credentials`), не в скрипте.
- Hardened runtime + дочерние процессы: обычно ок, но если Ollama-бинарь без подписи — может понадобиться `com.apple.security.cs.disable-library-validation`; проверяй на подписанной сборке, не на debug.
- zip через `ditto`, не `zip` — иначе подпись слетает.
