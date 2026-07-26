# Модуль MCP — правила

Subprocess-сервисы (Jira, Confluence, Git, Filesystem и т.п.) через Model Context Protocol на stdio. JSON-RPC 2.0 по одной строке на сообщение; корреляция ответов по int-id; tool-use цикл в чате (модель → инструмент → результат → модель).

## Что здесь живёт

- `MCPConnection` — одно живое соединение к серверу (subprocess + stdio); построчный фрейминг, буферизация partial-строк, корреляция ответов по id, гарантированное гашение процесса при выходе приложения (инвариант №2). Чистое ядро фрейминга вынесено в `MCPFraming` (extractLines/resolvePending, без Process) — юнит-тестируемо без subprocess.
- `MCPManager` — actor, агрегатор всех соединений; идемпотентное подключение, маршрутизация вызовов инструментов по `qualifiedName` (`<slug>__<tool>`), таймауты handshake (90 с) и call (120 с).
- `MCPProtocol` — типы: `JSONValue` (полиморфное JSON для схем и аргументов), `RPCRequest`/`RPCIncoming` (JSON-RPC 2.0 конверты), `MCPToolSpec` (от сервера), `ToolSpec` (для LLM), `MCPError` (LocalizedError), `withTimeout()` (task-группа с гонкой).
- `MCPServer` — конфиг subprocess (command/args/env); persisted в mcp-servers.json вне репо; поддержка `keychain:имя` для секретов (env-значения резолвятся при старте через KeyStore).
- `ProviderToolSupport` — sendWithTools для OpenAI (function calling) и Ollama (native tools, arguments — объект вместо строки, id синтезируется); конверсия ToolSpec → JSON Schema для моделей.
- `ToolUse` — tool-use цикл (порт из Manager Assistant): запрос с tools → ответ модели tool_calls → execute через замыкание (ошибки текстом ERROR) → добавляем assistant+tool → повтор до maxIterations; на финале форсируем текст (forceText).
- `ToolUseLoop.run()` — чистая логика цикла; на вызов ошибка возвращается текстом (execute-замыкание никогда не бросает), модель в цикле видит ERROR-префикс и может среагировать.
- `MCPServersSection` — UI управления серверами (список со статусами, редактирование, тест подключения, импорт конфига Claude Desktop).

## Инварианты

1. **Subprocess регистрируется в `BackgroundProcessRegistry` сразу после спавна** (MCPConnection.swift:95). Гарантированное гашение в `applicationWillTerminate` с эскалацией SIGTERM → 3 с → SIGKILL (инвариант №2 проекта). Чужой процесс, уже слушающий на сокет, не гасится.

2. **Построчный фрейминг (newline-delimited JSON, не Content-Length).** `MCPConnection.buffer` копит `Data` из AsyncStream (строка 109), `drainLines()` вызывает чистую `MCPFraming.extractLines()` (строка 123), которая ищет 0x0A и режет до него, пустые строки пропускает. Одна строка = один JSON-RPC объект. Это два разных сценария, не путать: (а) `\n` ещё не пришёл — данные просто лежат в `buffer` и ждут следующего чанка, ничего не теряется; (б) строка уже собрана (до `\n`), но не парсится как `RPCIncoming` (битый JSON, чужой формат) — `try? JSONDecoder()` в `MCPFraming.resolvePending()` (строка 34) вернёт `nil`, строка молча отбрасывается без следа.

3. **Корреляция ответов по int-id: словарь `pending: [Int: CheckedContinuation]`** (строка 52). При отправке запроса id инкрементируется (строки 130-131), continuation сохраняется в pending (строка 134). `MCPFraming.resolvePending()` (строки 33-42) — один `guard`: `method == nil` (это ответ, не запрос/нотификация сервера) и id, найденный в `pending`; если оба условия выполнены, continuation извлекается и резолвится. **Если id не найден в `pending` (или пришёл запрос/нотификация сервера) — `guard` проваливается, функция делает `return`, сообщение молча отброшено** — никакого `for`-цикла с `continue` здесь нет, control-flow — один guard-else-return. Таймаут на вызов 120 секунд (MCPManager:106): если ответ не пришёл за 120 с, гонка в `withTimeout()` бросает `MCPError.timeout`, continuation получит ошибку.

4. **Обрыв процесса сервера срывает все pending-ожидания.** Когда subprocess закрывает stdout, AsyncStream в `consume()` получает пусто (readabilityHandler отдаст `.availableData.isEmpty`), вызывает `cont.finish()` (строка 85), цикл `for await` выходит (строка 108), `running = false` (строка 113). После этого все continuation в pending получат `MCPError.process` с текстом stderr (строки 114-117). Новые запросы при `running == false` бросят `notConnected` (строка 129).

5. **Stderr копится в памяти, лимит 8000 символов** (строка 104). Обрезка при показе — в двух разных местах с разными числами, не путать: при ошибке `connect()` в диагностику статуса попадают последние **300** символов stderr (MCPManager:65); при обрыве уже установленного соединения (`consume()` срывает pending, см. пункт 4) — последние **400** символов (строка 116).

6. **Ошибки инструментов возвращаются текстом с префиксом ERROR.** `MCPConnection.callTool()` (строка 185) склеивает content.text, если `isError == true`, добавляет "ERROR: " (строка 195). `MCPManager.call()` (строка 99) **никогда не бросает** — все ошибки (маршрутизация, сеть, timeout) возвращаются текстом "ERROR: …", модель их видит и может запросить повтор.

7. **Таймауты:** handshake 90 с (MCPManager:47, npx может качать пакет), вызов инструмента 120 с (MCPManager:106).

8. **Параллельный reentry в `connect()` — не плодим процессы.** Set `connecting: Set<UUID>` блокирует параллельные вызовы для одного сервера (MCPManager:35-41). Если вторая корутина зайдёт в connect() пока первая коннектится, она получит старый `lastStatus` вместо нового соединения.

## Как тестируем

Без сети и без реального subprocess:

- `MCPConnectionTests` (`MCPConnectionTests.swift`) — `MCPFraming.extractLines`/`resolvePending`: частичное сообщение в одном чтении, сообщение из двух чтений, неизвестный id, обрыв потока посреди JSON, happy-path и error-path корреляции ответа с `CheckedContinuation` (через `withCheckedThrowingContinuation`).
- `MCPProtocolTests` (`MCPTests.swift`) — `JSONValue` (Int/Double порядок декода, round-trip схемы), `RPCRequest`/`RPCIncoming` (result/error/нотификация), `MCPManager.qualify()` (безопасность и обрезка имени).
- `ToolSchemaConversion` — конверсия схемы в OpenAI-tool и Gemini-functionDeclaration (в т.ч. не-объект схема, вырезание неподдерживаемых Gemini ключей) на фикстурах.
- `ToolUseLoop.run()` — чистая логика цикла на моке `ToolCapableChatProvider`: один/два шага, лимит итераций форсирует текст, ошибка сервера уходит в ERROR-текст без остановки цикла, пустой финальный текст с непустым транскриптом, полностью пустой ответ — `LLMError.emptyResponse`.
- `MCPServer` — `parseClaudeConfig`, разрешение `keychain:`-секретов и поведение при отсутствующем ключе (инжектируемый `KeyStore.key`), снисходительная миграция из минимального JSON.
- `OllamaParsing.parseChatToolResponse` — arguments-объект → JSON-строка, обычный текстовый ответ без tool_calls.

**Не покрыто юнит-тестами:** сам `MCPConnection` целиком (реальный `Process`, `start()`/`consume()` на живом AsyncStream) и подключение/переподключение/таймауты/reentry в `MCPManager` — `Process` не инжектируется, поднимать subprocess в тестах не с чем сравнить (как живое железо/Core Audio, см. `Tests/SecondBrainTests/CLAUDE.md`); проверяется вручную с настоящим MCP-сервером. Чистая логика фрейминга и корреляции (`MCPFraming`) вынесена и покрыта — см. выше.

## Частые ошибки прошлых задач

Пока нет.

## Куда не лезть

- Протокол инициализации и ответов — это MCP spec, не трогаем версию или формат, только применяем (ручка инструментов — `ToolUse.run`).
- Архитектуру tool-use цикла (вызов → результат → повтор) — это порт Manager Assistant, изменять по согласованию.
- Выбор провайдера и маршрутизацию в ChatViewModel — модуль `Chat/`, MCP здесь только поставляет инструменты.
- Prompt и контекст, в который вставляются инструменты — `Chat/`, не MCP.
