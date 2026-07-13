# 15 — MCP-клиент

## Цель
Чат умеет пользоваться инструментами MCP-серверов: пользователь настраивает серверы (в первую очередь Jira и Confluence), модель вызывает их инструменты в цикле tool-use.

## Зависимости
12.

## Контекст
В MA есть работающий MCP-клиент — портируй: `MCPClient.swift` (менеджер серверов, tool routing), `MCPProtocol.swift` (типы протокола, stdio transport), `MCPTests.swift`, конфиг в `mcp-servers.json`. Пользователю нужны Jira/Confluence — официальный путь: `mcp-remote`/atlassian remote MCP либо stdio-серверы (`npx`), это деталь конфигурации, не кода.

## Объём работ
- [ ] Портировать `MCP/`: протокольные типы (initialize, tools/list, tools/call), stdio-транспорт (Process — **регистрировать в BackgroundProcessRegistry из 09**, серверы должны умирать вместе с приложением), менеджер серверов (запуск по требованию, перезапуск упавшего, статус).
- [ ] Конфиг серверов: `mcp-servers.json` в Application Support (имя, команда, args, env; env может содержать ссылки на Keychain-ключи через KeyStore — токены Jira не в plaintext-конфиге). UI добавления/редактирования + импорт стандартного формата `mcpServers` из Claude Desktop (пользователю знаком).
- [ ] Tool-use цикл в чате: инструменты включённых серверов → в запрос провайдеру (OpenAI/Gemini/Ollama tools-формат — конверсия из MCP-схемы); ответ с tool_calls → вызов MCP → результат обратно в контекст → до финального текстового ответа (лимит итераций).
- [ ] Тумблер включённых серверов per-чат (как enabledMCPServerIDs в MA).
- [ ] UI: вызовы инструментов видны в чате (свёрнутый блок: имя, аргументы, результат); ошибки сервера — в UI, не молча.

## Вне объёма
Подтверждение каждого вызова (пока доверяем; заготовь точку для confirm-режима — 19), MCP-ресурсы и промпты (только tools), SSE/HTTP-транспорт, если его нет в MA (зафиксируй в «Результате», stdio достаточно для старта — Jira/Confluence доступны через mcp-remote по stdio).

## Критерии приёмки
- Тесты (порт MCPTests + новые): сериализация протокольных сообщений, конверсия MCP tool schema → формат OpenAI и Gemini, tool-use цикл на MockChatProvider + мок-MCP (одно- и двухшаговый сценарий, лимит итераций), падение сервера посреди вызова → понятная ошибка.
- Ручная проверка: подключить простой stdio-сервер (например `npx -y @modelcontextprotocol/server-filesystem` на временную папку) — модель в чате читает файл через инструмент; убить приложение — процессов серверов не осталось.

## Подсказки
- Проверь версию протокола в MCPProtocol.swift MA против актуальной спеки MCP — с момента написания могла уйти вперёд; фиксируй поддерживаемую версию в файловом заголовке.
- stdio-фрейминг MCP — JSON-RPC с разделением по строкам; буферизуй частичные строки.
- Не все модели одинаково хороши в tool-use — в подсказке UI отметь рекомендуемые (GPT-4o+, Gemini 2+; локальные — qwen3+).

## Результат

Выполнено; `swift build` (debug/release) и `swift test` зелёные (508 тестов, +20 новых).

**Что сделано** (порт MCPProtocol/MCPClient из MA + tool-use поверх наших провайдеров):

- `MCP/MCPProtocol.swift` — JSONValue (нетипизированный JSON, порядок проб Int→Double), JSON-RPC конверты (RPCIncoming снисходительный: method≠nil → серверный запрос, игнор), доменные типы, MCPError, withTimeout. **Версия протокола 2025-06-18** — подтверждена живым сервером (см. ниже).
- `MCP/MCPConnection.swift` — actor: подпроцесс `/usr/bin/env <command> <args>`, построчный JSON-RPC фрейминг (буферизация частичных строк, резка по 0x0A), корреляция ответов по id через continuations, stderr-диагностика, handshake initialize→initialized→tools/list (с пагинацией), tools/call (склейка content[].text, isError → ERROR-префикс). **Процесс регистрируется в BackgroundProcessRegistry** — серверы умирают вместе с приложением (SIGTERM→SIGKILL из 09). Падение сервера срывает pending-вызовы понятной ошибкой.
- `MCP/MCPManager.swift` — actor-агрегатор: идемпотентный connect (защита от реентранси), qualifiedName `<slug>__<tool>` (санитайз [A-Za-z0-9_-], ≤64), маршрутизация вызовов, call никогда не бросает (ERROR-текст для модели), таймауты 90 c handshake / 120 c вызов. Авто-перезапуска нет (как в MA): следующий ensureConnected пересоздаёт.
- `MCP/MCPServer.swift` — конфиг в стиле Claude Desktop + импорт `parseClaudeConfig`; **секреты: env-значение `keychain:<имя>` резолвится через KeyStore при запуске** (токены не в plaintext); PATH дополняется nvm/homebrew (GUI-.app из Finder не видит node); mcp-servers.json с карантином битого файла; шаблон Atlassian (mcp-remote, OAuth в браузере).
- `MCP/ToolUse.swift` — провайдеро-независимые DTO, протокол ToolCapableChatProvider, конверсия схем: **OpenAI** (схема как есть) и **Gemini** (рекурсивная чистка до OpenAPI-подмножества — тесты есть), цикл ToolUseLoop (порт runToolLoop MA: лимит 6, последняя итерация форсирует текст, транскрипт вызовов, суммирование usage).
- `MCP/ProviderToolSupport.swift` — sendWithTools для **OpenAIProvider** (function calling, отдельные DTO — стабильный код 08 не тронут) и **OllamaProvider** (native tools /api/chat; arguments-объект → строка, id синтезируется; tool_choice нет — forceText не шлёт tools).
- Чат: `ChatConfiguration.enabledMCPServerIDs` (per-чат, миграция), `ChatMessage.toolCalls: [ToolCallDisplay]?` (persisted), tool-use путь в ChatViewModel (без стриминга; провайдер без tools → понятная ошибка), меню «Инструменты» в тулбаре с подсказкой моделей (GPT-4o+, qwen3+), свёрнутый DisclosureGroup вызовов в сообщении (имя/аргументы/результат, ошибки оранжевым).
- UI настроек: секция MCP-серверов (статусы, тест подключения, редактор command/args/env/extraPATH, импорт Claude-конфига).

**Вне объёма / отклонения (зафиксировано)**:
- SSE/HTTP-транспорта нет и в MA — stdio достаточно (Jira/Confluence через mcp-remote по stdio). 
- **Gemini sendWithTools не подключён** (другой формат диалога parts/functionCall/functionResponse) — конверсия схемы готова и протестирована, вызовы — бэклог; чат с Gemini+инструментами даёт понятную ошибку.
- Подтверждение каждого вызова — точка заготовлена (execute-замыкание в MCPBridge), confirm-режим — задача 19.

**Тесты**: MCPProtocolTests (JSONValue Int/Double/round-trip, RPC-конверты, qualify), ToolSchemaConversionTests (OpenAI как есть + не-объект → пустая схема; Gemini-чистка $schema/additionalProperties/$comment на всех уровнях), ToolUseLoopTests (одношаговый, двухшаговый с проверкой assistant+tool сообщений и суммирования токенов, лимит с forceText на последней итерации, падение сервера → ERROR-результат и словесный ответ), MCPServerConfigTests (Claude-импорт, keychain-резолв, миграции, персистентность toolCalls), OllamaToolParsingTests (arguments-объект, синтез id).

**Ручная проверка (частично выполнена)**: живой `npx @modelcontextprotocol/server-filesystem` — initialize (протокол 2025-06-18 принят сервером), tools/list (инструменты со схемами), tools/call read_text_file (кириллица в пути и содержимом) — весь stdio-контракт подтверждён end-to-end. Осталось руками: полный цикл в UI чата с моделью (нужен API-ключ) и `pgrep -f server-filesystem` пуст после выхода из приложения.
