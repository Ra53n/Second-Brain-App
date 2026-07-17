# 28 — RAG работает и настраивается

## Цель
RAG перестаёт молча не работать: состояние базы видно чипом в чате (с действиями), выбор модели эмбеддинга в «Моделях» реально действует, реранк/переписывание запроса настраиваются отдельной функцией роутинга, у RAG-индекса доков проекта есть статус в настройках.

## Зависимости
13 (RAG-индексация), 14 (RAG в чате), 23 (настройки RAG в чате), 25 (доки проекта), 27 (чипы/вкладка «Инструменты»).

## Контекст (диагноз)
- Ретрив тихо возвращал nil без эмбеддинг-провайдера/индекса/при смене модели — «агенты не используют RAG» без объяснений.
- Модель эмбеддинга из роутинга игнорировалась: провайдеры зашивали свою (OpenAI → text-embedding-3-small, Ollama → nomic-embed-text), а тег индекса писался по строке роутинга — рассинхрон.
- Автодефолт эмбеддингов Ollama подставлял чат-модель qwen3:8b (descriptor.defaultModel) в тег.
- Реранк/переписывание использовали функцию «чат» без возможности выбрать модель.

## Объём работ
- [ ] `EmbeddingProvider.embed(_:model:)` + проброс модели через RagIndexer/RagRetriever/RagIndexManager/ProjectDocsRag/ProjectToolsProvider.
- [ ] `ProviderDescriptor.defaultEmbeddingModel` + `defaultModel(for:)`; автодефолт и вкладка «Модели» используют per-capability модель.
- [ ] `AppFunction.ragRerank` («RAG: переранжирование и переписывание запроса»); wireRagProvider резолвит её.
- [ ] Чип «База» в чате: ready/indexing/noEmbedder/empty/needsReindex, поповер с действиями (индексировать/переиндексировать/открыть настройки).
- [ ] Статус RAG-индекса доков во вкладке «Инструменты» (stats/reset).
- [ ] Тесты на всё перечисленное.

## Вне объёма
- Ленивая довычислка размерности кастомной модели (несовпадение ловится guard'ом поиска).
- Автозапуск Ollama из чипа.

## Критерии приёмки
- `swift build` и `swift test` зелёные.
- Вживую: тумблер «По базе» без эмбеддера → оранжевый чип с путём решения; после установки nomic-embed-text и индексации → зелёный «База · N»; строка «RAG: переранжирование…» видна в «Моделях».

## Результат

Сделано (2026-07-17):
- **Модель эмбеддинга сквозная**: протокол `embed(_:model:)` (extension-обёртка сохраняет старые вызовы), конформеры OpenAI/Gemini/Ollama/HashingEmbedder используют `model ?? свой дефолт`; модель прокинута через RagIndexer.sync, RagRetriever.search/retrieve, RagIndexManager (currentEmbeddingTag → тройка embedder/model/tag), ProjectDocsIndexService.helpBlock, ProjectToolsProvider.helpContext.
- **Per-capability дефолт**: `ProviderDescriptor.defaultEmbeddingModel` + `defaultModel(for:)`; Ollama регистрирует nomic-embed-text, OpenAI/Gemini — свои; `FunctionRouter.defaultAssignment` и подстановка модели в «Моделях» используют его. Фикс: авто-роутинг эмбеддингов Ollama больше не подставляет qwen3:8b.
- **`AppFunction.ragRerank`** — отдельная строка в «Моделях» (автодефолт — первый chat-провайдер, как раньше де-факто); wireRagProvider резолвит её.
- **Чип «База»** (`RagChipSummary` в ToolingStatus + `RagStatusChip` в ChatToolingViews): состояния ready («База · N», зелёный)/indexing (прогресс)/noEmbedder (оранжевый, «Открыть настройки» → Локальные модели)/empty («Индексировать» прямо из чата)/needsReindex («Переиндексировать заново»); приоритеты закреплены тестами. ChatDetailView наблюдает RagIndexManager.
- **Статус индекса доков**: `ProjectDocsIndexService.stats/reset` (+обёртки в ProjectToolsProvider), строка во вкладке «Инструменты» с кнопкой «Сбросить индекс».
- **Тесты** (+11): проброс модели (vault- и docs-индексация), ragRerank, embedding-автодефолт (регресс qwen3), RagChipSummary (5 состояний, nil, приоритеты), stats/reset. Всего 645 зелёные.

Решение по тегу: остаётся «model|dim» с dim от дефолта провайдера — инвалидацию покрывает компонент model; кастомная модель с другой размерностью даёт честный пустой поиск (guard в RagRetriever.search), задокументировано в currentEmbeddingTag.