# Конвенции кода

Практики унаследованы из эталонного проекта пользователя — **Manager Assistant** (`/Users/kostyanikitin/Desktop/Manager assistant`). Он работает, владельцу нравится, как он написан. Прежде чем реализовывать подсистему — открой аналог в MA и посмотри, как сделано там.

Здесь — **детали**. Правила, структура папок, нейминг, паттерны, антипаттерны и флоу работы над задачей — в [CLAUDE.md](../CLAUDE.md); специфика подсистемы — в `CLAUDE.md` её папки.

## Комментарии (на русском, минимум по делу)

Комментарий обязан добавлять то, чего в коде нет. Пересказ следующей строки — вода, удаляем.
Ориентир — ~10–15% строк-комментариев (не 40%). Правило: удали комментарий; если смысл не
потерялся — оставь удалённым.

1. **Файловый заголовок — 1 строка** назначения; +≤2 строки ТОЛЬКО на неочевидный
   инвариант/оговорку, которую из кода не вывести. Без блока «Здесь живут: …» — типы
   перечисляет сам код.
   ```swift
   // GitClient.swift — обёртка над git CLI (задача 16).
   // FIFO-очередь обязательна: параллельные git портят index.lock.
   ```
2. **`///`** — только где имя и сигнатура не объясняют суть (например, когда возвращается
   `nil`, неочевидный контракт). На самоочевидном члене — не пишем.
3. **Инлайн** — только «почему», которого нет в коде.

Расхождение с MA осознанное: по объёму комментариев мы легче. MA остаётся эталоном
архитектуры и паттернов, не плотности комментариев.

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

## Шаблоны

Перенесены из корневого `CLAUDE.md` (задача 61) — там осталась короткая ссылка сюда.

### Файл модуля

```swift
// ИмяФайла.swift — одна строка о назначении (задача NN).
// Важно: ≤2 строки ТОЛЬКО на неочевидную оговорку, которую из кода не вывести (иначе — нет).

import Foundation

struct Thing: Equatable {
    let id: String
}

enum ThingLogic {
    /// nil — когда вход не резолвится (единственное неочевидное в сигнатуре).
    static func compute(_ input: String) -> Thing? { ... }
}

enum ThingError: LocalizedError, Equatable {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name): return "«\(name)» не найдено"
        }
    }
}
```

Порядок: заголовок → `import` → доменные типы → основной тип → `extension` → ошибки.
Комментарии — минимум по делу: шапка 1 строка, `///` только где имя+сигнатура не объясняют
сами, инлайн — только «почему». Удалил комментарий и смысл не потерялся → удаляй.

### Тест

```swift
// ТемаTests.swift — тесты <чего> (задача NN).
//
// Что покрыто: перечисление групп случаев.

import XCTest
@testable import SecondBrain

final class ТемаTests: XCTestCase {

    func testОписаниеПроверяемогоПоведения() {
        for (input, expected) in [("a", 1), ("b", 2)] {
            // подпись в конце — чтобы из отчёта было видно, какой случай упал
            XCTAssertEqual(ThingLogic.compute(input), expected, input)
        }
    }
}
```

### Файл задачи `tasks/NN-slug.md`

`# Задача NN: название` → `## Тип` (баг / фича / рефакторинг / тест / документация —
детерминирует профиль исполнения: баг → `bugfix`, рефакторинг → `refactor`, фича/тест/
документация → `coder`; см. CLAUDE.md «Сценарные профили») → `## Модель` (`haiku` / `sonnet`
/ `inherit` — модель дев-субагента для `/execution-loop`, для обычного `/task-run` не
используется; `haiku` — когда объём точно описан, `sonnet`/`inherit` — когда есть развилки
суждения) → `## Цель` (что видит пользователь) → `## Зависимости` → `## Объём` (нумерованный
список работ с файлами) → `## Вне объёма` (что явно не трогаем) → `## Критерии приёмки`
(проверяемые утверждения) → после выполнения `## Результат`.
