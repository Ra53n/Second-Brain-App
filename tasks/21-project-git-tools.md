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
