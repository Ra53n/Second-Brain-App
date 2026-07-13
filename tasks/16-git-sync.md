# 16 — Git-синхронизация vault

## Цель
Vault синхронизируется через git прямо из приложения: статус, commit, push, pull, история, авто-бэкап по таймеру. Второй мозг консистентен между несколькими Mac.

## Зависимости
02.

## Контекст
Vault пользователя уже под git: `/Users/kostyanikitin/Documents/Obsidian Vault/Second_Brain`, remote `github.com/Ra53n/Second_Brain`, коммиты вида `vault backup: 2026-07-01 20:42:14` — воспроизводим этот UX штатно. **Важно**: сейчас в URL remote зашит PAT открытым текстом — приложение должно работать через системный credential helper (osxkeychain) или SSH и **предлагать** починить такой remote (убрать токен из URL), а не консервировать анти-паттерн.

## Объём работ
- [ ] `GitSync/GitClient.swift`: обёртка над git CLI через `Process` (детект бинаря: xcrun/`/usr/bin/git`); операции: status (porcelain v2), add -A + commit, push, pull (`--rebase=false`, обычный merge), log (последние N), diff имён файлов, remote -v, init. Все — async, с таймаутами, stderr в ошибки (`GitError: LocalizedError`).
- [ ] `GitSync/SyncViewModel.swift`: состояние (чистый/есть изменения/ahead/behind — по `status`+`rev-list --count`), операции с прогресс-индикацией, защита от параллельных операций.
- [ ] Vault без git: кнопка «Включить синхронизацию» → `git init` + первый коммит + (опционально) привязка remote, введённого пользователем.
- [ ] **Авто-бэкап**: таймер (настраиваемый интервал, дефолт выкл) — если есть изменения: commit `vault backup: <дата>` + push; ошибки пуша не теряются (баннер), очередные попытки не дублируют коммиты.
- [ ] Конфликты pull: автоматический merge не удался → прервать merge (`git merge --abort`), сообщить пользователю со списком конфликтных файлов и предложить: «принять свои» / «принять удалённые» / «открыть в Finder» (умный merge — не наша задача); vault никогда не остаётся в полу-смердженном состоянии.
- [ ] Auth: https-remote — через osxkeychain helper (проверка `git credential fill`); SSH — работает из коробки; **детект токена в URL remote** → предложение одним кликом переписать URL без токена (сам токен показать пользователю для сохранения). Пароли/токены приложение не хранит.
- [ ] UI: индикатор состояния синка в тулбаре (чисто/изменения/ahead/behind/ошибка), панель: изменённые файлы, кнопки Commit+Push / Pull, история коммитов.
- [ ] `.gitignore` vault: предложить добавить `.obsidian/workspace*`, `.DS_Store`, `Meetings/_recordings/` (большие аудио в git — спросить пользователя: игнорировать или LFS вручную).

## Вне объёма
Git LFS автоматизация, ветки/PR, построчный merge-редактор, синк не-git способами.

## Критерии приёмки
- Тесты: на temp-репозитории (реальный git CLI в тестах допустим): парсинг status porcelain, commit+log round-trip, детект ahead/behind между двумя temp-репо (bare remote), детект токена в URL, логика авто-бэкапа (мок-часы: нет изменений → нет коммита), сценарий конфликта → abort → чистый статус.
- Ручная проверка **на копии** vault пользователя (склонировать в temp): статус видит правки, commit+push в тестовый remote проходит, конфликт (правка одного файла с двух копий) обрабатывается без потери данных.

## Подсказки
- `Process` для git: наследуй окружение (`HOME`, `SSH_AUTH_SOCK`), иначе auth сломается; рабочая директория — корень vault.
- Все git-вызовы сериализуй в одну очередь — параллельные `git` в одном репо портят index.lock.
- Сообщения авто-коммитов — как у пользователя сейчас: `vault backup: YYYY-MM-DD HH:mm:ss`.

## Результат

Сделано по плану, все критерии приёмки закрыты.

- `GitSync/GitClient.swift` — actor-обёртка над git CLI: детект бинаря (/usr/bin, homebrew), FIFO-очередь операций (защита index.lock), таймауты со сторожевым SIGKILL, `GIT_TERMINAL_PROMPT=0` + ssh BatchMode (GUI никогда не виснет на запросе пароля), `core.quotepath=false` (кириллические пути). Операции: status porcelain v2, add -A + commit (без изменений коммит не создаётся), push (без upstream — фолбэк `push -u origin HEAD`), pull `--no-rebase` (+ `-X ours/theirs` для разрешения конфликтов), fetch, log, remote -v / set-url / add, init, `credential fill`-проверка (секреты не сохраняются). Парсеры — чистые enum: `GitStatusParser`, `GitLogParser`, `GitRemoteURL`.
- `GitSync/AutoBackup.swift` — чистая логика авто-бэкапа: `isDue` (мок-часы), `plan` (нет изменений → нет коммита; после неудачного push — только допушить, без дублей), формат сообщения `vault backup: YYYY-MM-DD HH:mm:ss`; + `GitignoreAdvisor` (рекомендации `.obsidian/workspace*`, `.DS_Store`, `Meetings/_recordings/` — записи встреч отдельной кнопкой, по выбору пользователя).
- `GitSync/SyncViewModel.swift` — состояние (noVault/checking/gitUnavailable/notARepo/ready), защита от параллельных операций (isBusy), таймер авто-бэкапа (тик 30 с, интервал персистентен в UserDefaults `gitSync.autoBackupMinutes`, дефолт выкл), включение синка (init + первый коммит + опц. remote), починка remote с токеном.
- `GitSync/GitSyncViews.swift` — индикатор в тулбаре (чисто/изменения/ahead/behind/ошибка) + popover-панель: изменённые файлы, Commit+Push / Pull / Обновить (fetch), история, авто-бэкап, `.gitignore`-рекомендации, баннер токена в URL, confirmationDialog конфликтов.
- Интеграция: ContentView — тулбар + attach на смену vaultURL.

Отклонения/решения:
- Конфликты: вместо «сохранить локальную копию с маркером» (старый текст ARCHITECTURE.md) — схема из этой задачи: abort → выбор «свои/удалённые/Finder»; ARCHITECTURE.md обновлён.
- Vault, вложенный в чужой git-репозиторий, считается «не репозиторием» (`rev-parse --show-toplevel` ≠ корень vault) — иначе приложение коммитило бы родительский репо целиком.
- ahead/behind берутся из `status --porcelain=v2 --branch` (`# branch.ab`), отдельный `rev-list --count` не нужен; актуализация — кнопкой «Обновить» (fetch).

Тесты: 27 новых (парсер status v2 включая пути с пробелами/кириллицей, детект/стрип токена в URL, авто-бэкап на мок-часах, .gitignore-советчик; интеграционные на реальном git: commit+log round-trip, отсутствие дублей коммитов, ahead/behind между двумя клонами bare-remote, конфликт → abort → чистый статус и целые данные, set-url). Всего 535 тестов зелёные.

Ручная проверка на копии реального vault (clone в temp): статус видит правки, commit+push в тестовый bare-remote проходит, конфликт двух копий → abort без потери данных. В реальном vault подтверждён PAT в URL remote — панель предложит починку.

Для задачи 17: интервал авто-бэкапа пока в UserDefaults (`gitSync.autoBackupMinutes`) — забрать в SettingsStore с миграцией; секция «Синхронизация» может переиспользовать SyncViewModel (он один на приложение, живёт в ContentView).
