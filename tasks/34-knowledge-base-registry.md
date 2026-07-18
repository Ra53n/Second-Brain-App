# 34 — Реестр баз знаний (multi-base RAG) + RAG как инструмент

## Цель
Бинарный переключатель «Vault | Проект» (задача 31) не масштабируется: пользователю нужен СПИСОК баз знаний (vault, репозиторий проекта, произвольные папки с .md), возможность включать несколько баз в одном чате и переключаться между ними. RAG при этом должен стать туллингом: модель с function calling получает инструмент `rag_search` и сама решает, когда и в какой базе искать (как уже работают git-инструменты и MCP), — это лечит и качество ответов «про себя»: модель переформулирует запрос и ищет несколько раз.

## Зависимости
27 (хаб инструментов), 31 (единый источник знаний).

## Объём работ
- [x] Реестр баз: `KnowledgeBase`/`KnowledgeBaseStore` (`knowledge-bases.json`, нормализация встроенных vault/project, папочные базы с UUID-id).
- [x] `FolderIndexService` + `FolderDocsLoader`: свой `folder-rag.sqlite` на папку, рекурсивный сбор .md с лимитами, ленивый sync по mtime, тег «model|dim».
- [x] `ChatConfiguration.enabledKnowledgeBaseIDs: Set<String>` (мультивыбор per-чат) + `ragAsTool: Bool`; миграция legacy `knowledgeSource` (vault→{"vault"}, project→{"project"}).
- [x] Инструмент `rag_search` (один, с параметром base — enum по именам включённых баз): схема/разбор/форматирование в `RagSearchTool`, слияние баз в `KnowledgeMerge`, исполнение в `KnowledgeBaseManager.executeSearchTool`.
- [x] Ветвление в `ChatViewModel.startGeneration`: tool-провайдер + ragAsTool → rag_search в tool-цикле (источники цепляются к сообщению из execute-замыкания с дедупом); иначе — статический `[RAG_CONTEXT]` через `KnowledgeBaseManager.retrieve` (спецслучай {vault} идёт старым пайплайном с rerank/rewrite).
- [x] UI: чип «База» с чекбоксами баз (per-чат) и per-base действиями; секция «Базы знаний (RAG)» на вкладке «Инструменты» (глобальные тумблеры, добавить папку, статистика, сброс, удаление); тумблер «RAG как инструмент» в параметрах RAG.
- [x] Тесты: стор/нормализация/карантин, загрузчик папок, FolderIndexService (инкрементальность, смена тега), definition/parse/format/merge, миграция конфига, строки и агрегат чипа.

## Вне объёма
- FSEvents/автопереиндекс папочных баз (только ленивый sync + «Сбросить индекс»).
- Rerank/query-rewrite для мульти-базового слияния (остаются в чисто-vault пути).
- Слияние ProjectDocsIndexService и FolderIndexService; перевод /help на реестр.
- Tools для Gemini; стриминг финального ответа tool-цикла.
- Кликабельность источников не-vault баз; прогресс-бар индексации папок.

## Критерии приёмки
- `swift build` и `swift test` зелёные.
- В чипе «База» видны все включённые базы реестра с чекбоксами; в настройках добавляется произвольная папка и появляется в чипе.
- С tool-провайдером (OpenAI/Ollama) модель вызывает `rag_search` (вызов виден в сообщении), источники-цитаты появляются под ответом.
- Провайдер без tools (или ragAsTool выключен) получает статический `[RAG_CONTEXT]` со слиянием включённых баз; чат с дефолтным конфигом ({vault}) ведёт себя как раньше.
- Старые чаты с `knowledgeSource` открываются без потерь.

## Результат

Сделано (2026-07-18): всё из объёма. Новые файлы: `RAG/KnowledgeBase.swift` (модель + стор), `RAG/FolderIndexService.swift` (лоадер с лимитами 1 МБ/2000 файлов + actor-владелец индексов папок), `RAG/RagSearchTool.swift` (чистая логика инструмента: definition с enum-уникализацией имён, parseArguments, formatResult с anti-injection и бюджетом, KnowledgeMerge со сквозной сортировкой по score и дедупом), `RAG/KnowledgeBaseManager.swift` (@MainActor-фасад: роутинг хитов по kind, retrieve со спецслучаем {vault} → старый RagIndexManager.retrieveForChat, executeSearchTool). `ProjectDocsIndexService` получил публичный `hits(...)`, `ProjectToolsProvider` — `projectHits(...)`. `RagChipSummary` реструктурирован: пер-базовые строки `KnowledgeBaseChipRow` (чистые билдеры vaultRow/projectRow/folderRow, case `repoMissing` → `pathMissing`) + агрегат (заголовок «База: Vault +1», худший health, isIndexing). `ToolsSettingsTab` получил `KnowledgeBasesSection`.

Важно агентам следующих задач:
- `KnowledgeSource` оставлен как legacy-тип ТОЛЬКО для миграции (CodingKey `knowledgeSource` читается, но не пишется; у `ChatConfiguration` теперь ручной `encode(to:)` — новые поля добавлять туда).
- rag_search добавляется в tools только когда провайдер ToolCapable и ragAsTool включён — проверка ДО Task в startGeneration (ragToolDefinition), маршрутизация в execute-замыкании по имени первым.
- Источники из tool-вызовов накапливаются `appendSources` (дедуп по RagSource.id, максимум score) — не путать с `attachSources` (замена, статический путь).
- Сквозной тест executeSearchTool через полный KnowledgeBaseManager не написан (менеджеру нужны VaultManager/RagIndexManager — тяжёлая арматура); покрытие собрано из частей: FolderIndexServiceTests (реальный ретрив по temp-папке) + KnowledgeMergeTests + RagSearchToolParseTests. 692 теста зелёные.

Ручная проверка (install.sh → перезапуск установленной копии → AX-обход): приложение стартует, раздел «Чат» рендерится с историей, чип «База» на месте; чат со старым `knowledgeSource: project` мигрировал — чип показывает «Поиск по документации репозитория готов · чанков: 53». Содержимое поповера чипа визуально не снято (окно на другом Space, screencapture не достаёт) — логика строк/агрегата закрыта юнит-тестами RagChipSummaryTests.
