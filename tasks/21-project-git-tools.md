# 21 — Встроенные git-инструменты проекта

## Цель
Ассистент в чате может «ходить» по выбранному git-репозиторию (репозиторий самого проекта, репозиторий vault или произвольная папка): смотреть ветки, статус, историю, список файлов и читать файлы. Инструменты встроены в приложение (без внешних MCP-процессов); дополнительно — шаблон подключения внешнего git MCP-сервера.

## Зависимости
15 (tool-use цикл в чате), 16 (GitClient).

## Контекст
Архитектура инструментов — по образцу пользователя: протокол Tool (name+description+parameters — информация для LLM, execute — логика), каждый инструмент — отдельный класс, ToolRegistry регистрирует инструменты, один общий ToolExecutor находит тулзу по имени, собирает контекст и выполняет. Имена встроенных инструментов не содержат `__`, поэтому не коллидируют с qualified-именами MCP (`slug__tool`).

## Объём работ
- [ ] GitClient: `branches()` (парсер `git for-each-ref`, паттерн GitStatusParser) и `trackedFiles()` (git ls-files).
- [ ] Модуль `Sources/SecondBrain/Tools/`:
  - `BuiltinTool.swift` — протокол BuiltinTool, ToolContext (repoRoot + разобранные аргументы), ToolResult (ok/error текстом);
  - `ToolRegistry.swift` — регистрация инструментов, findByName, definitions() → [ToolDefinition];
  - `ToolExecutor.swift` — actor: находит инструмент в регистраторе, выполняет, ошибки строкой `"ERROR: …"`;
  - `GitTools.swift` — пять классов: GitBranchesTool, GitStatusTool, GitLogTool (limit ≤ 50), ListFilesTool (cap 2000), ReadFileTool (только чтение, cap 64 КБ, отказ по бинарникам);
  - `SafePath.swift` — разрешение относительного пути строго внутри корня (нормализация, symlink, запрет `../`-побега).
- [ ] Настройка `AppSettings.projectRepoPath` + секция «Инструменты проекта» в общих настройках (Выбрать…/Текущий vault/Сбросить, предупреждение «не git-репозиторий»).
- [ ] Per-chat включение: `ChatConfiguration.projectToolsEnabled`, чекбокс в меню инструментов чата.
- [ ] Маршрутизация: второй мост projectToolsBridge в ChatViewModel; слияние с MCP-инструментами в send(); executor по имени (builtin → ToolExecutor, иначе MCP).
- [ ] `MCPServer.gitTemplate()` (uvx mcp-server-git) + кнопка «Git (шаблон)» в MCP-настройках.

## Вне объёма
- Write-операции из чата (commit, push, правка файлов) — при появлении обязателен режим confirm (бэклог, п. 16).
- Произвольный shell / выполнение команд.
- Checkout/переключение веток — только чтение.

## Критерии приёмки
- Тесты: парсер веток (текущая/remote/origin-HEAD/detached), SafePath (все виды побега), ToolRegistry/ToolExecutor (unknown tool, кривой JSON), каждый Git*Tool на временном git-репозитории, маршрутизация builtin/MCP в ChatViewModel, миграция settings.json.
- `swift build` и `swift test` зелёные.
- Вручную: выбрать репозиторий проекта в настройках, включить инструменты в чате, «покажи ветки» → в транскрипте виден вызов git_branches и корректный ответ.

## Результат

Сделано (2026-07-16):
- **GitClient** ([GitSync/GitClient.swift]): `GitBranches` + чистый парсер `GitBranchParser` (формат `%(HEAD)%09%(refname:short)%09%(refname)` — полный refname надёжно отличает локальную ветку со слэшем от remote), `branches()`, `trackedFiles()`.
- **Новый модуль `Sources/SecondBrain/Tools/`** (архитектура Tool/Registry/Executor по образцу пользователя):
  - `BuiltinTool.swift` — протокол BuiltinTool (name/description/parameters — для LLM, execute — логика), ToolContext (repoRoot + разобранные аргументы, хелперы input/intInput), ToolResult (ok/error текстом), хелперы схем ToolSchemas;
  - `ToolRegistry.swift` — регистратор (findByName/names/definitions) + фабрика `projectTools(repoRoot:)`;
  - `ToolExecutor.swift` — actor-исполнитель: поиск по имени, разбор argumentsJSON, ошибки строкой `ERROR:`;
  - `GitTools.swift` — пять классов: GitBranchesTool, GitStatusTool, GitLogTool (limit ≤ 50), ListFilesTool (ls-files, фолбэк ФС-обход, cap 2000, фильтр path), ReadFileTool (только чтение, cap 64 КБ, NUL-детект бинарников);
  - `SafePath.swift` — разрешение путей строго внутри корня (симлинки резолвятся у корня и кандидата);
  - `ProjectToolsProvider.swift` — @MainActor владелец пары (registry, executor) с кэшем по пути; живёт в AppModel.
- **Настройки**: `AppSettings.projectRepoPath` (+миграция), секция «Инструменты проекта (чат)» в Общих (Выбрать…/Текущий vault/Сбросить + async-предупреждение «не git-репозиторий»).
- **Чат**: `ChatConfiguration.projectToolsEnabled` (per-чат, migration-safe), `ChatViewModel.ProjectToolsBridge` (второй мост; available/tools/execute), `toggleProjectTools()`, слияние инструментов и маршрутизация в send() по именам хода (builtin-имена без `__` → project, иначе MCP; tool-путь срабатывает и без MCP-серверов), пункт «Инструменты проекта (git)» в меню инструментов + счётчик источников.
- **MCP**: `MCPServer.gitTemplate()` (uvx mcp-server-git, enabled=false, предзаполнение projectRepoPath), кнопка «Git (шаблон)»; `MCPSettingsTab` получил SettingsStore.
- **Тесты** (ProjectToolsTests.swift, 7 сьютов + дополнения SettingsTests): парсер веток, SafePath (включая symlink-побег), registry/executor, интеграционные Git*Tool на temp-репозиториях, маршрутизация двух мостов через scripted-провайдер, миграции. Всего 580 тестов зелёные.

Отклонения: вместо `names: Set<String>` в мосте — имена вычисляются на каждый ход из `tools()` (проще и всегда согласовано с реальным набором). Для агентов задачи 22: включить project-tools принудительно на один ход можно через тот же мост + слияние в send() (см. TurnOverrides в плане).
