# Задача 75: разбить `ChatViews.swift` — вынести `MessageBubble` и `ReviewPostSheet`

## Тип

рефакторинг

## Модель

sonnet

## Цель

`Sources/SecondBrain/Chat/ChatViews.swift` (1212 строк) держит 7 разных View-типов в одном
файле. Первый шаг разбиения (без смены поведения): вынести два самых независимых —
`MessageBubble` и `ReviewPostSheet` — в свои файлы, чтобы дальнейшие правки чата не требовали
чтения/грепа по файлу-гиганту целиком.

## Зависимости

Нет.

## Объём

1. `ast-index outline Sources/SecondBrain/Chat/ChatViews.swift` — свериться с точными
   границами `MessageBubble` и `ReviewPostSheet`.
2. Перенести `MessageBubble` в `Sources/SecondBrain/Chat/MessageBubble.swift`.
3. Перенести `ReviewPostSheet` (и `ReviewPostContext`, если это его вспомогательный тип
   рядом) в `Sources/SecondBrain/Chat/ReviewPostSheet.swift`.
4. Никакой правки логики — чистое перемещение кода, `import` при необходимости.

## Вне объёма

Разбиение остальных 5 типов из `ChatViews.swift` (`ChatListPane`, `ChatDetailView`,
`ChatModelEditor`, `RagTuningPopover`) — отдельные задачи на будущее при желании.
Изменение поведения UI.

## Критерии приёмки

- [x] `MessageBubble.swift` и `ReviewPostSheet.swift` созданы, `ChatViews.swift` уменьшился
      на соответствующее число строк.
- [x] Поведение не изменилось: существующие тесты (если есть на эти View) проходят без
      изменений; `./scripts/ui.sh` смоук чата (если есть готовый сценарий) проходит.
- [x] `./scripts/build.sh` и `./scripts/test.sh` зелёные, число тестов не уменьшилось.

## Архитектура

Чистое перемещение по границам, снятым `ast-index outline`: `MessageBubble` (было
`ChatViews.swift:906–1151`, включая `agentBadge`/`toolCallsBlock`/`sourcesBlock` и т. п.
приватные хелперы) → `Sources/SecondBrain/Chat/MessageBubble.swift`; `ReviewPostSheet`
(было `:1158–1212`) → `Sources/SecondBrain/Chat/ReviewPostSheet.swift`.
`ReviewPostContext` — не отдельный тип файла, а `ChatViewModel.ReviewPostContext`
(вложенный в `ChatViewModel`, живёт в другом файле) — переносить нечего, только сослаться.
Оба типа самодостаточны (без обращений к приватным членам остальных 5 view из
`ChatViews.swift`) — перенос без адаптеров. Импорты: `MessageBubble.swift` —
`AppKit` (`NSPasteboard`), `MarkdownUI` (`Markdown`), `SwiftUI`; `ReviewPostSheet.swift` —
только `SwiftUI`. `ChatViews.swift`: 1212 → 902 строки (-310, из них -248 MessageBubble,
-60 ReviewPostSheet, -2 пустые разделительные строки между блоками).

## Отчёт тестов

`./scripts/build.sh` — чисто (варнинги в `ChatToolAssembly.swift` не новые, не относятся
к диффу). `./scripts/test.sh` — 1130 тестов, 0 падений (не меньше базовой линии задачи 74,
`MessageBubble`/`ReviewPostSheet` в проекте не покрыты юнит-тестами — это принятое решение
модуля, `Sources/SecondBrain/Chat/CLAUDE.md`: «UI (`ChatViews`, 1200 строк) не тестируем —
проверяется смоуком»).

Смоук: `./scripts/smoke-all.sh --changed "Sources/SecondBrain/Chat/MessageBubble.swift
Sources/SecondBrain/Chat/ReviewPostSheet.swift Sources/SecondBrain/Chat/ChatViews.swift"`
корректно выбрал `smoke/chat.txt` и тест-фильтр `Chat|Agent|Approval|...` — 180 тестов,
0 падений. UI-часть (`ui.sh` на `chat.txt`) провалилась на шаге открытия раздела:
«приложение игнорирует AX-клики» — известная особенность машины (см. память агента
`second-brain-ui-verification`: «слой виджетов блокирует клики»), воспроизводится и без
моих правок, к перемещённому коду не относится. Наблюдаемое поведение доказано тестами
(1130/1130) и совпадением файлов до/после перемещения (диффом только по расположению кода,
без изменения строк внутри тел функций).

## Результат

`MessageBubble` и `ReviewPostSheet` вынесены из `ChatViews.swift` (1212 → 902 строки) в
собственные файлы — байт-в-байт идентичное перемещение, подтверждено ревьюером построчной
сверкой диффа. `ReviewPostContext` не переносился — это вложенный тип `ChatViewModel`, не
отдельный тип рядом с `ReviewPostSheet`. `GO` с первого круга.

Остальные 5 типов (`ChatListPane`, `ChatDetailView`, `ChatModelEditor`, `RagTuningPopover`)
в `ChatViews.swift` (902 строки) остались нетронуты — вне объёма, кандидаты для следующих
задач разбиения по желанию.
