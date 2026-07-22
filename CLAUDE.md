# Second Brain — правила проекта

macOS-приложение «второй мозг»: аналог Obsidian с записью встреч, транскрипцией через
выбираемые LLM (локальные и облачные), чатом по базе знаний (RAG), MCP-интеграциями
(Jira, Confluence) и git-синхронизацией vault. Swift/SwiftUI, ~28 тыс. строк, 1000+ тестов.

**Этот файл — правила и процесс: как писать, как проверять, что запрещено.** Он главный;
при расхождении с другими документами прав он.

| Где | Что там |
|---|---|
| `CLAUDE.md` (здесь) | правила, конвенции, антипаттерны, флоу работы над задачей |
| `Sources/**/CLAUDE.md` | специфика модуля — подхватывается автоматически при работе с его файлами |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | принятые решения, модули, потоки данных. Меняешь решение — обновляешь |
| [docs/DATA-MODEL.md](docs/DATA-MODEL.md) | что и где хранится: файлы, JSON, SQLite, Keychain |
| [docs/VISION.md](docs/VISION.md) | зачем всё это, сценарии пользователя |
| [docs/CONVENTIONS.md](docs/CONVENTIONS.md) | детали стиля комментариев, тестов, персистентности + таблица портирования из Manager Assistant |
| [tasks/00-INDEX.md](tasks/00-INDEX.md) | все задачи, зависимости, статусы |
| [tasks/BACKLOG.md](tasks/BACKLOG.md) | единый бэклог: всё, что ещё не стало задачей |

## Стек

| Слой | Выбор | Почему |
|---|---|---|
| Язык/UI | Swift 5.9+, SwiftUI (+AppKit для системного) | macOS-only; нужен нативный доступ к аудио, процессам, Keychain |
| Сборка | SPM-only executable, без .xcodeproj | `swift build` из CLI; `.app` собирает `run.sh` |
| Минимальная ОС | macOS 14+ | Core Audio process tap для системного звука (14.4+) |
| Заметки | обычные .md на диске, Obsidian-совместимо | данные переживут приложение |
| Индексы | SQLite: FTS5 (поиск) + таблица векторов (RAG) | системный libsqlite3, без зависимостей; всегда пересоздаваемы |
| Локальный LLM | Ollama как управляемый child-процесс | меньше своего кода, проверено в Manager Assistant |
| Локальная транскрипция | WhisperKit (CoreML), in-process | лучший Whisper на Apple Silicon |
| Облако | OpenAI, Gemini, Deepgram, AssemblyAI, OpenRouter, DeepSeek | за единой абстракцией провайдеров |
| Git | обёртка над git CLI через `Process` | без libgit2; auth — системный credential helper или SSH |
| Зависимости | ровно две: MarkdownUI, WhisperKit | каждая новая зависимость обсуждается с владельцем |

## Архитектура в десяти строках

`AppModel` — корень объектного графа, владелец менеджеров и сторов; связки «настройка ↔
поведение» держит он (Combine). UI — `NavigationSplitView` с разделами (заметки, поиск,
встречи, чат, пайплайны). У каждой области один `@MainActor ViewModel` — единственный
владелец мутабельного состояния; View только читают. Внешние сервисы спрятаны за
протоколами (`ChatProvider`, `TranscriptionProvider`, `EmbeddingProvider`), выбор
конкретного — за `FunctionRouter` (функция → провайдер → модель). Долгие процессы — FSM с
персистентным контекстом (встреча, прогон агента, пайплайн). Инструменты LLM (встроенные +
MCP) сводятся в один набор в `ChatToolAssembly` и проходят через слой разрешений.
Детали и потоки данных — [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Инвариант №1: vault — источник истины

Приложение работает поверх живой папки пользователя (возможно, его рабочего Obsidian
vault). Никакая операция не теряет и молча не перезаписывает .md. Все производные данные
(FTS-индекс, векторы, кэши) лежат **вне** vault — в
`~/Library/Application Support/SecondBrain/<vault-id>/` — и пересоздаваемы: удаление
индекса не должно стоить пользователю ничего, кроме времени переиндексации.

### Инвариант №2: жизненный цикл фоновых процессов

Любой запущенный приложением процесс регистрируется в `BackgroundProcessRegistry`,
поднимается лениво, гасится по idle-таймауту и **гарантированно** убивается в
`applicationWillTerminate` (SIGTERM → 3 с → SIGKILL). Чужой, не нами запущенный сервер
не гасится никогда.

## Структура папок

```
Sources/SecondBrain/
  App/          точка входа, AppDelegate, AppModel, ContentView, Config
  Vault/        дерево vault, CRUD, FSEvents, security-scoped bookmarks, пути
  Editor/       markdown-редактор поверх NSTextView, concealment, автосохранение
  Links/        [[wikilinks]], frontmatter, граф ссылок и backlinks
  Search/       SQLite FTS5, quick switcher
  Audio/        запись микрофона и системного звука, конвертация, метаданные
  LLM/          протоколы провайдеров, реестр, роутинг «функция → модель», Keychain
    Cloud/      OpenAI, Gemini, Deepgram, AssemblyAI, HTTP-хелперы, чанкер аудио
  LocalRuntime/ Ollama-процесс, скачивание моделей, WhisperKit, реестр процессов
  Meetings/     FSM встречи: запись → транскрипция → summary → заметка
  Chat/         чаты, персистентность, промпты, инструменты, панель изменений
    AgentFSM/   FSM-прогон ответа: чистый редьюсер + оркестратор
  RAG/          чанкинг, эмбеддинги, векторный индекс, retriever, реестр баз знаний
  MCP/          MCP-клиент (stdio), конфиг серверов, tool-use цикл
  Pipelines/    автоматизации: cron, PR-watch, движок прогонов
    CodeReview/ GitHub-клиент, сборка ревью-инпута, раннер
  Tools/        встроенные инструменты чата, файловые операции, слой разрешений
  GitSync/      git-операции, авто-бэкап, история
  Settings/     окно настроек, SettingsStore, проверка ключей
Tests/SecondBrainTests/   зеркало модулей; Fixtures/ — реальные ответы API
docs/           ARCHITECTURE, DATA-MODEL, CONVENTIONS, VISION
tasks/          00-INDEX, BACKLOG, файлы задач NN-slug.md
.claude/        agents/ — субагенты, skills/ — команды цикла разработки
run.sh install.sh dist.sh   сборка .app, установка, дистрибуция
```

Модули — папки одного SPM-таргета, не отдельные таргеты: тесты через
`@testable import SecondBrain`.

## Нейминг

Идентификаторы английские, комментарии и пользовательские строки русские.

| Имя | Роль | Примеры |
|---|---|---|
| `*ViewModel` | `@MainActor final class … : ObservableObject`, единственный владелец мутабельного состояния области | `ChatViewModel`, `MeetingsViewModel`, `SearchViewModel` |
| `*Store` | персистентность Codable→JSON, публикует загруженное | `SettingsStore`, `PipelineStore`, `MeetingStore`, `KnowledgeBaseStore` |
| `*Manager` | владелец подсистемы или ресурса на всё приложение | `VaultManager`, `MCPManager`, `OllamaManager`, `RagIndexManager` |
| `*Provider` | реализация протокола внешнего сервиса | `OpenAIProvider`, `WhisperKitProvider`, `OllamaProvider` |
| `*Client` | обёртка над внешним процессом или HTTP API | `GitClient`, `GitHubClient` |
| `*Service` | фоновая работа, обычно `actor` | `FolderIndexService`, `ProjectDocsIndexService` |
| `*Parser` `*Chunker` `*Detector` `*Splitter` | чистые функции без I/O | `WikilinkParser`, `RagChunker`, `CodeRegionDetector` |
| `*Models.swift` | доменные типы модуля, без логики UI | `ChatModels`, `PipelineModels`, `MeetingModels` |
| `*Views.swift` `*Pane` `*Section` `*View` | SwiftUI-слой | `ChatViews`, `MeetingsPane`, `RagStatusSection` |
| `*Tool` / `*Tools.swift` | реализация `BuiltinTool` | `RagSearchTool`, `FileTools`, `GitTools` |
| `enum *Error: LocalizedError` | ошибки подсистемы; `Equatable`, если проверяются в тестах | `GitError`, `MeetingError`, `LLMError` |
| `<Тема>Tests.swift` | `final class ТемаTests: XCTestCase`, методы `testЧтоИменноПроверяем` | `ToolPermissionsTests`, `VaultPathTests` |

## Паттерны, которые используем

**P1. Чистое ядро + тонкий оркестратор.** Решающая логика — в чистую функцию или `enum`
без I/O; оркестратор только гоняет сеть/диск/LLM и персистит. Чистое ядро тестируется
исчерпывающе и без моков. Эталоны: `AgentPhaseReducer` (все переходы FSM чата),
`MeetingFSM.transitions`, `PipelineScheduling`, `MeetingFolderPicker`, `VaultPath`,
`ToolRiskClassifier`.

**P2. Store.** Codable→JSON в Application Support, запись `.atomic`; битый файл уезжает в
`*.corrupt.json` и приложение стартует с пустого; автосохранение — debounce 300 мс на
`@Published`; снисходительный `init(from:)` (`decodeIfPresent` + дефолт) и **тест миграции
на каждое новое поле**. Эталоны: `ChatPersistence`, `SettingsStore`, `MeetingStore`.

**P3. Протокол → реестр → исполнитель.** Новая сущность добавляется файлом и строкой
регистрации, вызывающий код не меняется. `BuiltinTool` → `ToolRegistry` → `ToolExecutor`;
`ChatProvider`/`TranscriptionProvider` → `ProviderRegistry` → `FunctionRouter`.

**P4. Actor на разделяемый ресурс.** Всё, к чему могут обратиться параллельно, живёт в
`actor`: `GitClient` (FIFO-очередь — параллельные git портят `index.lock`), `MCPManager`,
`ToolExecutor`, `FileOpsContext`, индексные сервисы.

**P5. Crash-safety долгих процессов.** `persistNow()` синхронно после каждого перехода
FSM; на старте зависшие `running` → `paused`; resume идемпотентен (повтор шага безопасен);
гонки закрываются поколением (`agentGen`, `pipelineGen`) — сверка после каждого `await`.
Эталоны: `MeetingPipeline`, `ChatViewModel+AgentRun`, `PipelineEngine`.

**P6. Ошибка доходит до человека.** Своя `enum *Error: LocalizedError` на подсистему с
текстом, пригодным для показа в UI. Для инструментов LLM ошибка — это результат с текстом
`ERROR: …`, модель на него реагирует. Молча проглотить ошибку нельзя.

## Пять эталонов: так выглядит хороший код проекта

| Файл | Чему учиться |
|---|---|
| [Tools/BuiltinTool.swift](Sources/SecondBrain/Tools/BuiltinTool.swift) | минимальный протокол + хелперы схем: новый инструмент — один файл без правки инфраструктуры |
| [Chat/AgentFSM/AgentPhaseReducer.swift](Sources/SecondBrain/Chat/AgentFSM/AgentPhaseReducer.swift) | чистое ядро FSM: «контекст + текст → новый контекст», переходы только здесь |
| [Tools/ToolPermissions.swift](Sources/SecondBrain/Tools/ToolPermissions.swift) | чистый классификатор риска + строгий декодер: незнакомое значение «из будущего» → самый безопасный режим |
| [Vault/VaultPath.swift](Sources/SecondBrain/Vault/VaultPath.swift) | вычисления без обращения к ФС → тесты без temp-директорий; ловушки вроде префикса имён папок закрыты явно |
| [Chat/ChatStore.swift](Sources/SecondBrain/Chat/ChatStore.swift) | персистентность на 35 строк: атомарная запись, карантин битого файла, ноль паник |
| [Tests/…/ToolPermissionsTests.swift](Tests/SecondBrainTests/ToolPermissionsTests.swift) | эталон теста: таблица случаев циклом, говорящие имена, проверка граничных значений |

## Антипаттерны: запрещено

Каждый пункт проверяем grep'ом, и сейчас проект им соответствует — не сломай.

1. **`print()` / `NSLog()` для диагностики.** Сейчас в `Sources/` ноль вхождений. Ошибка
   идёт в `enum *Error` и доводится до UI, а не в консоль.
2. **SQL и `sqlite3_*` вне двух файлов** — [RAG/RagIndex.swift](Sources/SecondBrain/RAG/RagIndex.swift)
   и [Search/SearchIndex.swift](Sources/SecondBrain/Search/SearchIndex.swift). Никаких
   запросов из ViewModel, View или сервисов: им нужен метод индекса, а не строка SQL.
3. **Сеть в тестах.** Только фикстуры (`Tests/SecondBrainTests/Fixtures`), моки
   (`MockProviders`, `HashingEmbedder`) и инжектируемый транспорт (`GitHubClient`).
   Тест, который ходит в интернет, красный в самолёте — значит, бесполезный.
4. **Force unwrap на рантайм-данных.** `try!` и `!` допустимы ТОЛЬКО для компайл-тайм
   констант: статические `NSRegularExpression` и литеральные `URL(string:)` — так сейчас
   и есть. Данные от модели, сети, диска и пользователя — через `guard`/`throw`.
5. **Логика в `View`.** SwiftUI-структура читает состояние и вызывает методы ViewModel.
   Мутабельное состояние, I/O, разбор строк, обращения к диску в `body` — запрещено.
6. **`Process` мимо `BackgroundProcessRegistry`** и секреты в коде, логах, git-URL.
   Ключи живут в Keychain (fallback — env) и не показываются в UI никогда, даже частично.
7. **Запись в vault мимо `VaultFileOperations`** и mtime-guard `FileOpsContext`;
   производные данные (индексы, кэши, БД) внутри vault. См. инвариант №1.
8. **Правка файлов вне «Объёма» текущей задачи.** Заметил проблему рядом — запиши в
   `tasks/BACKLOG.md`, не чини по дороге.

## Шаблоны

### Файл модуля

```swift
// ИмяФайла.swift — одна строка о назначении (задача NN).
//
// Здесь живут:
//  - Тип1 — что это;
//  - Тип2 — что это.
//
// Поток данных: кто вызывает → что происходит → куда уходит результат.
// Важно: неочевидная оговорка, из-за которой сделано именно так.

import Foundation

/// Доменный тип: одна строка сути.
struct Thing: Equatable {
    let id: String            // стабильный идентификатор, переживает перезагрузку
}

/// Основной тип файла: чем владеет и что гарантирует.
enum ThingLogic {
    /// Что делает, что возвращает и когда возвращает nil.
    static func compute(_ input: String) -> Thing? { ... }
}

/// Ошибки подсистемы — с текстом для пользователя.
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

`# Задача NN: название` → `## Цель` (что видит пользователь) → `## Зависимости` →
`## Объём` (нумерованный список работ с файлами) → `## Вне объёма` (что явно не трогаем) →
`## Критерии приёмки` (проверяемые утверждения) → после выполнения `## Результат`.

## Флоу работы с любой входящей задачей

Задача приходит как одна фраза пользователя, пункт бэклога или файл в `tasks/`. Кодить
начинаем только после Ф2. Каждая фаза — свой скилл (см. ниже).

**Ф1. Интервью.** Веди себя как senior/staff-инженер, которому принесли запрос: пока не
поймёшь сценарий и границы, не проектируй. Обязательный чек-лист вопросов пользователю:

- Кто и в каком сценарии этим пользуется, что происходит непосредственно до и после?
- Пустой ввод, битый ввод, огромный ввод — что должно произойти?
- Нет сети, нет ключа, не скачана модель, нет прав (микрофон, папка) — как ведём себя?
- Краш или выход посреди операции — что пользователь увидит после перезапуска?
- Два одновременных запуска (два окна, пайплайн + руки) — что выигрывает?
- Уже сохранённые данные и настройки — нужна ли миграция, что со старыми файлами?
- Что явно НЕ надо делать в этой задаче?
- Как ты сам проверишь, что готово?

Спрашивай пачкой, а не по одному. Неочевидные ответы дословно уходят в файл задачи —
следующий агент не станет переспрашивать.

**Ф2. Архитектурный разбор.** Наложи задачу на существующую систему:

- в какой модуль ложится и почему именно туда;
- **что уже есть и переиспользуется** — обязательный поиск по коду до создания нового
  файла (половина «новых» задач закрывается существующим типом);
- какие инварианты затрагиваются (vault, фоновые процессы, персистентность);
- где чистое ядро (P1), где оркестратор, что персистится и как мигрирует (P2);
- какие существующие тесты придётся изменить — если много, вероятно, решение неверное;
- есть ли готовый аналог в Manager Assistant (таблица в CONVENTIONS.md).

**Ф3. Оформление.** Файл `tasks/NN-slug.md` по шаблону + строка в `00-INDEX.md`; если
задача выросла из бэклога — пункт там помечается `→ NN`.

**Ф4. Реализация.** Порядок: чистое ядро → тесты на него → интеграция → UI. Только то,
что в «Объёме». Комментарии — по ходу, не потом.

**Ф5. Проверка.** `swift build` и `swift test` зелёные; критерии приёмки проходятся по
пунктам с доказательствами; UI-задача — смоук всех кнопок затронутых экранов через
Accessibility; `git grep -I --cached -e 'sk-' -e 'ghp_' -e 'AIza'` пусто.

**Ф6. Закрытие.** `## Результат` в файле задачи (что сделано, отклонения от плана, что
важно знать следующим агентам), чекбокс в `00-INDEX.md`, обновление ARCHITECTURE.md при
смене архитектурного решения, коммит с осмысленным сообщением.

## Скиллы

| Команда | Фаза | Что делает |
|---|---|---|
| `/task-new` | Ф1+Ф3 | интервью по чек-листу corner-кейсов → файл задачи → строка в INDEX |
| `/task-plan` | Ф2 | архитектурный разбор, что переиспользовать, точки изменения, риски |
| `/task-run` | Ф4 | проверка зависимостей, реализация по конвенциям в правильном порядке |
| `/task-verify` | Ф5 | сборка, тесты, критерии по пунктам, AX-смоук UI, проверка секретов |
| `/task-close` | Ф6 | Результат, INDEX, ARCHITECTURE, коммит |
| `/port-from-ma` | — | портирование подсистемы из Manager Assistant с тестами |
| `/smoke-ui` | — | osascript-рецепты проверки UI через Accessibility |

## Субагенты

| Агент | Когда звать |
|---|---|
| `product-analyst` | пришла сырая идея — нужно допросить пользователя и оформить задачу |
| `architect` | задача понятна, надо разложить по системе и найти переиспользуемое |
| `coder` | есть план — реализовать объёмный кусок |
| `tester` | нужны тесты на новую логику или охота за непокрытыми случаями |
| `ui-engineer` | SwiftUI-слой и смоук интерфейса через Accessibility |
| `reviewer` | перед коммитом проверить диф на конвенции, антипаттерны, инварианты |

Экономия обязательна: субагент — на объёмную независимую работу, а не на «прочитать три
файла» (это дешевле сделать самому). Результат субагента не перепроверяется вручную и не
переделывается — либо доверяем, либо не звали.

## Жёсткие правила

- **Одна сессия — одна задача.** Возьми задачу из `tasks/`, проверь по `00-INDEX.md`, что
  её зависимости выполнены (нет — остановись и скажи пользователю), прочитай файл целиком,
  сделай только её. Нет подходящей задачи — она заводится из `BACKLOG.md` через `/task-new`.
- **Секреты** никогда не попадают в код и git. Keychain, fallback — env.
- **Vault пользователя — источник истины.** Не терять, не перезаписывать молча.
- **Фоновые процессы** регистрируются и гасятся при `applicationWillTerminate`.
- **Тесты обязательны**: задача не выполнена без тестов на новую core-логику.
- **UI проверяется вживую** через Accessibility: окно приложения исключено из захвата
  экрана (`kCGWindowSharingState = 0`), скриншоты дают обои — см. `/smoke-ui`.
- **После `install.sh` перезапусти приложение сам** (quit → open → проверь `pgrep`), не
  проси об этом пользователя.
- Реальный vault для ручных проверок — `/Users/kostyanikitin/Documents/Obsidian Vault/Second_Brain`:
  только чтение, ничего не ломать.
- Эталонный проект `/Users/kostyanikitin/Desktop/Manager assistant` — источник проверенных
  решений. Перед реализацией подсистемы с нуля проверь таблицу портирования в
  [CONVENTIONS.md](docs/CONVENTIONS.md).

## Сборка и тесты

```bash
swift build                # debug-сборка
swift run                  # запуск для разработки (без .app)
./run.sh                   # release + сборка SecondBrain.app
./install.sh               # run.sh + установка в /Applications

# Тесты требуют полный Xcode toolchain (не Command Line Tools)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
```
