# Архитектура Second Brain

Живой документ: агент, меняющий архитектурное решение, обязан обновить этот файл.

## Стек

| Слой | Выбор | Почему |
|---|---|---|
| Язык/UI | Swift 5.9+, SwiftUI (+AppKit для системных вещей) | macOS-only; нативный доступ к аудио, процессам, Keychain; эталонный проект пользователя (Manager Assistant) на том же стеке |
| Сборка | SPM-only executable, без .xcodeproj | Как в Manager Assistant: `swift build` из CLI, `.app` собирает `run.sh` |
| Минимальная ОС | macOS 14+ | Core Audio process tap для записи системного звука (14.4+); MA был на 13 — поднято осознанно |
| Хранилище заметок | Обычные .md файлы на диске (Obsidian-совместимо) | Данные переживут приложение; vault открывается в Obsidian |
| Индексы | SQLite (FTS5 для поиска, таблица векторов для RAG) | Всегда пересоздаваемы из vault; system libsqlite3 без внешних зависимостей |
| Локальный LLM-рантайм | Ollama как управляемый child-процесс | Проверенный паттерн MA (RagOllamaLauncher); API для скачивания моделей, чата, эмбеддингов |
| Локальная транскрипция | WhisperKit (CoreML) | Лучший Whisper на Apple Silicon; работает in-process |
| Облачные провайдеры | OpenAI, Gemini, Deepgram/AssemblyAI | Требование пользователя; за единой абстракцией, добавление новых тривиально |
| Git | Обёртка над git CLI через `Process` | Без libgit2-зависимостей; auth через системный credential helper / SSH |

## Инвариант №1: vault — источник истины

Приложение работает поверх выбранной пользователем папки (возможно, это его живой Obsidian vault). Отсюда:
- никакая операция не должна терять/молча перезаписывать пользовательские файлы;
- все производные данные (FTS-индекс, векторный индекс, кэши) лежат вне vault (`~/Library/Application Support/SecondBrain/<vault-id>/`) и пересоздаваемы;
- доступ к папке — через security-scoped bookmark, переживающий перезапуск.

## Инвариант №2: жизненный цикл фоновых процессов

Любой процесс, запущенный приложением (Ollama, будущие рантаймы):
- регистрируется в `LocalRuntimeManager` (единый владелец PID);
- запускается лениво — при первом запросе к локальной модели;
- гасится по idle-таймауту (настраиваемому; дефолт 10 мин, `IdleShutdownPolicy`);
- **гарантированно** убивается в `applicationWillTerminate`: SIGTERM → grace-период 3 с → SIGKILL выжившим (`BackgroundProcessRegistry.terminateAll`);
- сигнал шлётся группе процесса (killpg), если ребёнок стал её лидером, иначе самому процессу — Foundation.Process не даёт установить process group при spawn (нет POSIX_SPAWN_SETPGROUP), поэтому дерево Ollama гасится через его собственную корректную обработку SIGTERM;
- чужой (не нами запущенный) сервер не гасится никогда — ни по idle, ни при выходе;
- WhisperKit — не процесс, а in-process CoreML-модель (гигабайты RAM): та же `IdleShutdownPolicy` выгружает её из памяти после простоя (`WhisperKitProvider.unloadIfIdle`), кэш моделей — в `Application Support/SecondBrain/WhisperKit` (виден UI управления).

## Модули (папки внутри Sources/SecondBrain/)

```
App/          — точка входа, AppDelegate, корневой ContentView (NavigationSplitView)
Vault/        — модель vault: дерево, CRUD, FSEvents, security-scoped bookmarks
Editor/       — markdown-редактор, рендер, автосохранение
Links/        — парсинг [[wikilinks]] и frontmatter, граф ссылок, backlinks
Search/       — SQLite FTS5, quick switcher
Audio/        — запись микрофона и системного звука
LLM/          — протоколы провайдеров, реестр, роутинг функция→модель, облачные клиенты
LocalRuntime/ — менеджер Ollama-процесса, скачивание моделей, WhisperKit
Meetings/     — FSM-пайплайн встречи: запись → транскрипция → summary → раскладка
Chat/         — чаты, персистентность, PromptBuilder
RAG/          — чанкинг, эмбеддинги, векторный индекс, retriever
MCP/          — MCP-клиент (stdio), конфиг серверов, tool-use цикл
GitSync/      — git-операции, авто-бэкап, история
Settings/     — окно Settings (Cmd+,, вкладки), SettingsStore, KeyStore (Keychain)
Persistence/  — общие сторы (Codable→JSON, атомарная запись, миграции)
```

Модули — папки одного таргета (как в MA), не отдельные SPM-таргеты: меньше церемоний, тесты через `@testable import SecondBrain`.

## Схема данных

Что и где хранится (Application Support, vault, Keychain, схемы SQLite) — отдельный документ [DATA-MODEL.md](DATA-MODEL.md).

## Ключевые потоки данных

**Запись** (задача 06): дорожки стримятся на диск как AAC-в-CAF (CAF валиден на любом префиксе — kill -9 не теряет записанное; .m4a финализируется только при закрытии), при штатной остановке перепаковываются в `.m4a` без перекодирования; осиротевшие после краша `.caf` подхватывает `AudioFileConverter.recoverOrphans` при следующем запуске. Комбинированный режим «микрофон + система» — **две дорожки в два файла** (`<base>.m4a` + `<base> (система).m4a`), без реалтайм-микса: два clock-домена мешать сложно и рискованно, а транскрипции раздельные дорожки удобнее. Системный звук — Core Audio process tap (macOS 14.4+; на старее — graceful fallback на микрофон). Метаданные записи — sidecar `<base>.json` рядом с аудио (самодостаточность + уезжает с vault при git-синхронизации).

**Встреча** (задача 11): `Audio` пишет .m4a в `<vault>/Meetings/_recordings/` → `Meetings` FSM (`recorded → transcribing → transcribed → summarizing → awaitingTitle → filing → done` + `failed` с ретраем шага; таблица переходов — `MeetingFSM.transitions`, статус прогона поверх этапа — `MeetingRunStatus`; персистентно в Application Support, `persistNow()` после каждого перехода, зависшие `running` → `paused` на старте, resume идемпотентен) → `LLM` роутер: транскрипция — функция `.transcription` (все дорожки записи), summary — `.meetingSummary` (структурный промпт `[TRANSCRIPT]`/`[VAULT_FOLDERS]`/`[USER_RULES]`, ответ с маркерами `TITLE:`/`FOLDER:`/`SUMMARY:`; длинный транскрипт — map-reduce чанками ~24 тыс. символов) → название задано до записи — сразу filing, иначе диалог подтверждения → заметка `<vault>/<папка>/YYYY-MM-DD <название>.md` (frontmatter: дата, длительность, провайдер, ссылки на аудио; summary; транскрипт с таймкодами). Папку от LLM валидируем по дереву vault, фолбэк — `Meetings/YYYY-MM`; правила раскладки пользователя — `MeetingSettings.filingRules`.

**RAG** (задача 13): FSEvents (`diskChangeTick` VaultManager, debounce 2 с) сообщает об изменениях → инкрементальный реиндекс ТОЛЬКО изменённых по mtime файлов (чанкинг по заголовкам с путём «H1 > H2» и диапазонами строк; заголовки в код-блоках игнорируются → эмбеддинги батчами по 16 через роутер `.embedding` → SQLite `<vault-id>/rag.sqlite`: чанки и Float32-LE-векторы вместе, коммит per-file транзакцией — прерывание не теряет готовое). Автообновление активно только когда индекс уже построен (первая индексация — явная кнопка: эмбеддинги не бесплатны). Поиск — brute-force косинус по всем векторам (`Vector.topK`, семантика FAISS Flat): для личного vault в тысячи чанков это миллисекунды, sqlite-vec не нужен. Смена модели эмбеддинга детектится тегом «model|dim» в БД → предложение полной переиндексации (векторы несовместимы). Исключения: dot-папки, `Meetings/_recordings/`, не-markdown, пользовательский ignore-список. В чате retriever достаёт top-K чанков → в промпт `[RAG_CONTEXT]` → ответ с цитатами `[[заметка]]` (задача 14).

**Чат**: история чатов в Application Support (не в vault); системный промпт собирает ChatPromptBuilder (база + `[RAG_CONTEXT]` + `[TOOLS]`).

**MCP** (задача 15): серверы — конфиг в стиле Claude Desktop (`mcp-servers.json` в Application Support, импорт поддержан); секреты в env через синтаксис `keychain:<имя>` резолвятся из Keychain при запуске. Транспорт — stdio (JSON-RPC 2.0, построчный фрейминг, протокол 2025-06-18; Jira/Confluence — через `mcp-remote`); процессы серверов регистрируются в `BackgroundProcessRegistry` и умирают вместе с приложением. Tool-use цикл: инструменты включённых per-чат серверов → function calling провайдера (OpenAI и Ollama; Gemini — только конверсия схемы, вызовы в бэклоге) → исполнение через `MCPManager` (ошибки текстом `ERROR:`, модель на них реагирует) → до текстового ответа, лимит 6 итераций (последняя форсирует текст). При включённых инструментах ответ приходит без стриминга.

**Настройки** (задача 17): объектный граф приложения создаёт `AppModel` (владелец — `SecondBrainApp`, общий для главного окна и SwiftUI-сцены `Settings` — стандартное окно Cmd+, со вкладками: Общие/Провайдеры/Модели/Встречи/Локальные модели/MCP/Синхронизация). «Одиночные» значения (dot-папки, авто-открытие vault, интервал авто-бэкапа, idle-таймаут рантаймов) — в `SettingsStore` (settings.json, паттерн ChatStore, одноразовая миграция из старых UserDefaults-ключей); специализированные сторы (routing.json, mcp-servers.json, meeting_settings.json, Keychain) остаются на месте, а связки «настройка ↔ поведение» держит AppModel (Combine, двусторонние с removeDuplicates). Запись meeting_settings.json — только через `MeetingSettingsStore.update` (load-modify-save): файл редактируют два UI. Ключи провайдеров не отображаются никогда (только статус «задан»); проверка ключа — дешёвый GET списочного эндпоинта, секрет только в заголовке (`KeyVerifier`).

**Git** (задача 16): обёртка над git CLI (`GitClient`, actor с FIFO-очередью — параллельные git портят index.lock; парсеры porcelain v2/log/URL — чистые enum). Ручные commit/push/pull из панели в тулбаре + опциональный авто-бэкап по таймеру (`vault backup: <дата>` — как пользователь делает сейчас; неудачный push не дублирует коммиты — следующий прогон видит ahead>0 и допушивает). Конфликты pull: автоматический merge не удался → `merge --abort` (vault никогда не остаётся полу-смердженным) → пользователь выбирает «принять свои»/«принять удалённые» (`pull -X ours/theirs`) или мержит руками через Finder. Auth: только системный credential helper (osxkeychain) или SSH, интерактивные запросы отключены; токен в URL remote детектится и предлагается к удалению из URL (секрет показывается пользователю, приложение его не хранит). Vault, вложенный в чужой репозиторий, репозиторием не считается — защита от коммита родительского репо.

## Что портируется из Manager Assistant

Полная таблица — в [CONVENTIONS.md](CONVENTIONS.md#что-портировать-из-manager-assistant). Портирование = скопировать файл, переименовать под наш домен, адаптировать, сохранить стиль комментариев и принести тесты.

## Решения, принятые владельцем

- Swift/SwiftUI, а не KMP — macOS-only, системные API важнее знакомого стека.
- Ollama, а не встроенный llama.cpp — меньше своего кода, проверено в MA.
- Провайдер транскрипции по умолчанию не фиксируем: пользователь сравнит OpenAI/Deepgram/AssemblyAI/Gemini на своих встречах (см. задачу 19 — инструмент сравнения).
- Дистрибуция (задача 18): только arm64 (Mac пользователя — Apple Silicon; WhisperKit/Ollama целятся в него); подпись ad-hoc + hardened runtime + entitlement микрофона (ветка Б — Developer ID сертификата в Keychain нет), ветка А (Developer ID + нотаризация) заготовлена в dist.sh и включается автоматически при появлении сертификата. Версия — из git-тега в Info.plist.
