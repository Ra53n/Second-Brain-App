# Схема данных Second Brain

Живой документ (задача 20): где и в каком формате приложение хранит данные. Главный принцип — **инвариант №1**: vault пользователя — источник истины; всё в Application Support — производное и пересоздаваемое (кроме историй чатов/встреч — они первичны, но не критичны для vault).

## Два хранилища

| Хранилище | Путь | Что там | Судьба при удалении |
|---|---|---|---|
| **Vault** | папка, выбранная пользователем (Obsidian-совместимая) | заметки .md, записи встреч, sidecar-метаданные | потеря пользовательских данных — приложение обязано не допускать |
| **Application Support** | `~/Library/Application Support/SecondBrain/` | настройки, истории, индексы, кэши моделей | безопасно: индексы пересоздаются, настройки — к дефолтам |

## Application Support/SecondBrain/ — раскладка

| Файл/папка | Владелец в коде | Формат |
|---|---|---|
| `settings.json` | `SettingsStore` (Settings/) | JSON `AppSettings` |
| `chats.json` | `ChatPersistence` (Chat/ChatStore.swift) | JSON `[Chat]` |
| `mcp-servers.json` | `MCPServerStore` (MCP/MCPServer.swift) | JSON `[MCPServer]` |
| `routing.json` | `FunctionRoutingStore` (LLM/FunctionRouting.swift) | JSON `FunctionRoutingConfig` |
| `meetings.json` | `MeetingStore` (Meetings/) | JSON — прогоны пайплайна встреч |
| `meeting_settings.json` | `MeetingSettingsStore` (Meetings/MeetingSettings.swift) | JSON — правила раскладки, промпт-правила |
| `finetune-runs.json` | `FineTunePersistence` (FineTune/FineTuneStore.swift) | JSON — прогоны дообучения, гиперпараметры, разобранные точки loss; результаты последней валидации по датасету, пороги `--min-assistant` (задача 82) и счётчики примеров baseline `baselineCountOverrides` (задача 83) |
| `<vault-id>/search.sqlite` | `SearchIndex` (Search/) | SQLite FTS5 — полнотекстовый индекс заметок |
| `<vault-id>/rag.sqlite` | `RagIndex` (RAG/) | SQLite — чанки и векторы RAG |
| `<repo-id>/project-docs.sqlite` | `ProjectDocsIndexService` (Tools/) | SQLite (схема RagIndex) — RAG-индекс README+docs выбранного репозитория для /help |
| `WhisperKit/` | WhisperKit-провайдер (LocalRuntime/) | кэш скачанных CoreML-моделей Whisper |

`<vault-id>` — стабильный id открытого vault: первые 16 hex-символов SHA-256 от стандартизованного пути папки (`VaultID.make`, Vault/VaultTree.swift). У каждого vault — свои индексы.

`finetune-runs.json` лежит плоско, без `<vault-id>`: датасеты дообучения живут в репозитории проекта (`projectRepoPath`), а не в vault. Сами адаптеры, `runs/run.json` и `runs/train.log` пишет python-тулчейн в `finetune/<workdir>/` — приложение их только читает; в `.gitignore` они уже исключены. Приложение пишет в `finetune/` три вещи (задача 83): импортированный датасет (`<имя>/data/*.jsonl` + meta + `split.json` + `system_prompt.txt`), `baseline/` через запуск `baseline.py` и `criteria.md` (генерация LLM или редактор).

### Общие конвенции персистентности

- **Атомарная запись**: `data.write(options: .atomic)` — файл не бывает полузаписанным.
- **Снисходительное декодирование**: каждое поле через `decodeIfPresent` с дефолтом — старый JSON обязан загружаться после любого обновления приложения. Новые поля добавляются только со значением по умолчанию.
- **Карантин битых файлов**: не декодировался → переименовывается в `<имя>.corrupt.json`, приложение стартует с дефолтами (данные не затираются молча).
- **SQLite-индексы всегда пересоздаваемы** из vault: их можно удалить без потери данных.

### settings.json — AppSettings

| Поле | Дефолт | Смысл |
|---|---|---|
| `showsDotItems` | `false` | показывать dot-папки (.obsidian, .git…) в дереве vault |
| `restoreLastVault` | `true` | открывать последний vault при запуске |
| `autoBackupMinutes` | `0` | интервал git-авто-бэкапа, минуты; 0 — выключен |
| `localIdleMinutes` | `10` | idle-таймаут локальных рантаймов (Ollama, WhisperKit) |

Одноразовая миграция при первом запуске: старый ключ UserDefaults `gitSync.autoBackupMinutes` (задача 16) подтягивается в файл.

### chats.json — [Chat]

Иерархия (Chat/ChatModels.swift):

```
Chat            id, title, messages: [ChatMessage], configuration, createdAt
                (runtime-поля isLoading/errorText НЕ персистятся)
ChatMessage     id, role (system|user|assistant; незнакомая → assistant),
                content, metrics?, sources? [RagSource], toolCalls? [ToolCallDisplay], createdAt
MessageMetrics  promptTokens?/completionTokens?/totalTokens? (nil при стриминге), duration
ChatConfiguration
                providerID?/model?         — nil → роутер функции .chat решает сам
                temperature (1.0), historyWindow (20; окно истории для модели)
                ragEnabled (false), ragTopK (4), ragMinScore (0),
                ragRerankEnabled (false), ragQueryRewrite (false)
                enabledMCPServerIDs: Set<UUID> — MCP-серверы этого чата
```

`sources` — цитируемые чанки RAG-ответа (имя заметки, путь, заголовочный путь, score). `toolCalls` — транскрипт вызовов инструментов (имя, аргументы JSON, результат, ok/fail) для UI.

### mcp-servers.json — [MCPServer]

Конфиг в стиле Claude Desktop: `id, name, command (дефолт "npx"), args, env, enabled, extraPATH`. Поддержан импорт JSON-блока `mcpServers` из конфига Claude Desktop.

**Секреты**: значение env вида `keychain:<аккаунт>` резолвится из Keychain при запуске сервера (`MCPEnv.resolveSecret`) — токены не лежат в plaintext. Имена инструментов для LLM квалифицируются как `<slug>__<tool>` (slug — имя сервера в a–z0–9_, ≤24 символов; `MCPManager.qualify`) — по `__` ответный вызов маршрутизируется обратно на сервер.

### routing.json — FunctionRoutingConfig

Словарь «функция → назначение»: ключ — `AppFunction.rawValue` (`transcription`, `meetingSummary`, `chat`, `embedding`), значение — `{providerID, model}`. Отсутствие назначения → автодефолт роутера (первый доступный провайдер с нужной способностью). Назначение недоступного провайдера не ломает приложение — действует автодефолт, а вкладка «Модели» показывает предупреждение (`RoutingValidator`).

### meetings.json и meeting_settings.json

`meetings.json` — прогоны FSM встречи (этап `recorded → transcribing → … → done`, статус, пути артефактов); персист после каждого перехода, зависшие `running` при старте → `paused`, resume идемпотентен. `meeting_settings.json` — настройки пайплайна (правила раскладки по папкам и т.п.); запись только через `MeetingSettingsStore.update` (load-modify-save — файл редактируют два UI).

### search.sqlite (FTS5)

Таблицы: `files(path, mtime)` — инкрементальность; виртуальная `notes` (FTS5) — полнотекстовый индекс содержимого заметок. Пересоздаётся кнопкой «Пересоздать индекс».

### rag.sqlite

```sql
meta   (key TEXT PRIMARY KEY, value TEXT)   -- embeddingTag ("model|dim"), updatedAt
files  (path TEXT PRIMARY KEY, mtime REAL)  -- что и когда проиндексировано
chunks (id INTEGER PK AUTOINCREMENT, path, heading, line_start, line_end,
        text, vec BLOB, dim)                -- чанк + Float32-LE вектор
```

Чанкинг — по markdown-заголовкам (путь «H1 > H2» в `heading`). Обновление файла — одна транзакция (delete+insert+upsert mtime): прерывание оставляет БД консистентной. Несовпадение `embeddingTag` с текущей моделью роутера → векторы несовместимы, нужна полная переиндексация (RAG в чате в этом состоянии молча выключается). Поиск — brute-force косинус в памяти.

## Vault — что приложение пишет и что не трогает

Пишет:
- заметки, созданные пользователем через редактор, и заметки встреч `<vault>/<папка>/YYYY-MM-DD <название>.md`;
- записи встреч в `<vault>/Meetings/_recordings/`: дорожки `<base>.m4a` (+ `<base> (система).m4a` в комбинированном режиме) и sidecar `<base>.json` (`RecordingMetadata`: schemaVersion, date, duration, source, files) — метаданные лежат рядом с аудио, чтобы запись была самодостаточной и уезжала с vault при git-синхронизации.

Никогда: не удаляет и молча не перезаписывает пользовательские .md; не кладёт индексы/кэши внутрь vault; `Meetings/_recordings/` и dot-папки исключены из RAG-индексации.

Доступ к папке vault — security-scoped bookmark в UserDefaults (`vault.last.bookmark`, `vault.recent.bookmarks`), переживает перезапуск.

## Keychain

Сервис `com.local.second-brain.apikeys` (`KeyStore`, LLM/KeyStore.swift): account — `ProviderID.rawValue`, значение — API-ключ провайдера. Fallback — переменные окружения. Ключи никогда не показываются в UI (только статус «задан») и никогда не попадают в файлы/git. Тот же KeyStore обслуживает `keychain:`-синтаксис env MCP-серверов.

## UserDefaults (остаточные ключи)

- `vault.last.bookmark`, `vault.recent.bookmarks` — security-scoped bookmarks vault.
- `gitSync.autoBackupMinutes` — легаси, мигрирован в settings.json.

## Внутренний API инструментов чата

- `ToolDefinition {name, description, schema}` — описание инструмента для LLM (JSON Schema аргументов); конвертация в формат OpenAI/Gemini — `ToolSchemaConversion` (MCP/ToolUse.swift).
- Tool-use цикл — `ToolUseLoop.run` (лимит 6 итераций, последняя форсирует текст); ошибки исполнения возвращаются модели строкой `ERROR: …`, а не исключением — модель может отреагировать.
- Провайдер должен реализовывать `ToolCapableChatProvider` (OpenAI-совместимые и Ollama; Gemini — в бэклоге).
- Имена MCP-инструментов содержат `__` (`slug__tool`); встроенные инструменты приложения (задача 21) используют имена без `__` — пространства не пересекаются.
