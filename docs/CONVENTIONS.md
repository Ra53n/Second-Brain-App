# Конвенции кода

Практики унаследованы из эталонного проекта пользователя — **Manager Assistant** (`/Users/kostyanikitin/Desktop/Manager assistant`). Он работает, владельцу нравится, как он написан. Прежде чем реализовывать подсистему — открой аналог в MA и посмотри, как сделано там.

Здесь — **детали**. Правила, структура папок, нейминг, паттерны, антипаттерны и флоу работы над задачей — в [CLAUDE.md](../CLAUDE.md); специфика подсистемы — в `CLAUDE.md` её папки.

## Комментарии (обязательны, на русском)

Как в MA — плотное осмысленное покрытие:

1. **Файловый заголовок** (3–10 строк): назначение файла, что здесь живёт, поток данных, важные оговорки. Пример из MA (`Models.swift`):
   ```swift
   // Models.swift — доменная модель и DTO для API.
   //
   // Здесь живут:
   //  - доменные типы: Chat, ChatMessage, GenerationSettings ...
   //
   // Важно: «память» модели реализована повторной отправкой ВСЕЙ истории
   // чата в каждом запросе (API stateless) — поэтому promptTokens растут.
   ```
2. **`///` док-комменты** на каждый публичный/внутренний тип и нетривиальный метод — одна строка сути.
3. **Инлайн-комменты** у неочевидных полей (`let duration: TimeInterval // время ответа, сек (wall-clock)`).
4. Комментируем **почему**, а не что делает следующая строка.

## Тесты (обязательны)

- XCTest; запуск: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift test`.
- Покрывается вся core-логика: FSM, парсеры, миграции, чанкинг/индексы, DTO-сериализация, роутинг. UI-слой не тестируем.
- Паттерны из MA:
  - FSM — исчерпывающая проверка таблицы переходов по всем парам состояний (`FSMTests.swift`);
  - парсеры — round-trip + edge cases (пустое, битое);
  - миграции — старый JSON без новых полей обязан грузиться (`MigrationTests.swift`);
  - детерминированные моки вместо сети (`HashingEmbedder`), SQLite `:memory:` для индексов;
  - `@testable import SecondBrain`.
- Ориентир покрытия MA: ~165 тестов на ~13 тыс. строк.

## Персистентность (паттерн ChatStore)

- Codable → JSON в `~/Library/Application Support/SecondBrain/`, запись `.atomic`.
- Автосохранение: `debounce(300 мс)` на `$published`-поле, запись в `DispatchQueue.global(qos: .utility)`.
- Битый файл не роняет приложение: переносится в `*.corrupt.json`, стартуем с пустого.
- **Миграции**: снисходительный `init(from:)` — каждое поле через `decodeIfPresent` с дефолтом; на каждое новое поле — тест в MigrationTests.
- Crash-safety для пайплайнов (FSM встречи): `persistNow()` синхронно после каждого шага; на старте `normalize*()` переводит зависшие `.running` → `.paused`; resume идемпотентен.

## Состояние, ошибки, секреты

Правила вынесены в [CLAUDE.md](../CLAUDE.md): нейминг и роль `*ViewModel`/`*Store`/`*Manager`,
паттерн P6 «ошибка доходит до человека», антипаттерны 5–6 (логика в View, секреты и процессы).
Здесь не дублируем, чтобы не разъезжались две формулировки одного правила.

## Что портировать из Manager Assistant

Абсолютные пути; переносить с адаптацией под наш домен, вместе с тестами.

| Подсистема | Файлы MA | Используется в задаче |
|---|---|---|
| FSM (таблица переходов, guarded transitions, TaskContext) | `Sources/ManagerAssistant/Models.swift` (TaskFSM/TaskState/TaskContext), `Tests/ManagerAssistantTests/FSMTests.swift` | 11, 35 |
| FSM-оркестратор чата (runStateMachine: гейты, ретраи, pipelineGen, pauseAt) | `Sources/ManagerAssistant/ChatViewModel.swift:698-1052`, `Models.swift` (PipelinePrompts) | 35 |
| Персистентность | `Sources/ManagerAssistant/ChatStore.swift`, `MemoryStore.swift`, `Tests/.../MigrationTests.swift` | 02+, все сторы |
| PromptBuilder / PipelinePrompts (структурные маркеры `[STATE]`, `[RAG_CONTEXT]`…) | `Sources/ManagerAssistant/Models.swift` | 11, 12, 14 |
| HTTP-клиент LLM (OpenAI-совместимый, DTO, ошибки) | `Sources/ManagerAssistant/DeepSeekClient.swift`, `Providers.swift`, `Config.swift` | 07, 08 |
| RAG-пайплайн целиком | `Sources/ManagerAssistant/RagChunking.swift`, `RagEmbedding.swift`, `RagVectorIndex.swift`, `RagSQLiteIndex.swift`, `RagPipeline.swift`, `RagRetriever.swift`, `RagRerank.swift`, `Tests/.../RagTests.swift` | 13, 14 |
| MCP-клиент (stdio transport, tool routing) | `Sources/ManagerAssistant/MCPClient.swift`, `MCPProtocol.swift`, `Tests/.../MCPTests.swift` | 15 |
| Лаунчер локального рантайма (spawn/stopIfSpawned, cleanup в applicationWillTerminate) | `Sources/ManagerAssistant/RagOllamaLauncher.swift` | 09 |
| Вход в приложение (AppDelegate, activation policy, иконка) | `Sources/ManagerAssistant/App.swift` | 01 |
| Сборка .app | `run.sh`, `install.sh`, `icon/render_icon.swift` | 01, 18 |
