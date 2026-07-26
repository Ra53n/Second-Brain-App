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

- [ ] `MessageBubble.swift` и `ReviewPostSheet.swift` созданы, `ChatViews.swift` уменьшился
      на соответствующее число строк.
- [ ] Поведение не изменилось: существующие тесты (если есть на эти View) проходят без
      изменений; `./scripts/ui.sh` смоук чата (если есть готовый сценарий) проходит.
- [ ] `./scripts/build.sh` и `./scripts/test.sh` зелёные, число тестов не уменьшилось.
