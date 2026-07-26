# Задача 76: разбить `ChatViewModel.swift` — вынести вложенные bridge-классы

## Тип

рефакторинг

## Модель

sonnet

## Цель

`Sources/SecondBrain/Chat/ChatViewModel.swift` (886 строк) объявляет внутри самого класса
шесть вложенных bridge-классов (`MCPBridge`, `ProjectToolsBridge`, `ChatGitBridge`,
`RagToolBridge`, `ReviewPostContext`, `TurnOverrides`). Каждый логически независим и может
жить в своём файле — правка одного bridge сегодня требует открыть файл на 886 строк целиком.

## Зависимости

Нет.

## Объём

1. `ast-index outline Sources/SecondBrain/Chat/ChatViewModel.swift` — свериться с точными
   границами каждого вложенного типа.
2. Вынести каждый bridge-класс в свой файл (`Sources/SecondBrain/Chat/MCPBridge.swift` и
   т.д. — точное имя файла на усмотрение исполнителя по конвенции `*Bridge.swift`),
   сохранив их как расширение/вложенный тип `ChatViewModel`, если они были вложенными —
   т.е. `extension ChatViewModel { final class MCPBridge {...} }` в отдельном файле, а не
   плоский верхнеуровневый тип (не менять видимость/API).
3. Никакой правки логики.

## Вне объёма

Изменение публичного API `ChatViewModel`, слияние/переименование bridge-классов.

## Критерии приёмки

- [x] Шесть новых файлов созданы, `ChatViewModel.swift` уменьшился на соответствующее число
      строк, вложенность типов (namespace) сохранена.
- [x] Поведение не изменилось: существующие тесты на `ChatViewModel`/агентский FSM проходят
      без изменений.
- [x] `./scripts/build.sh` и `./scripts/test.sh` зелёные, число тестов не уменьшилось.

## Архитектура

Шесть вложенных типов вынесены из тела `class ChatViewModel` в отдельные файлы через
`extension ChatViewModel { struct X { ... } }` — namespace `ChatViewModel.X` не изменился,
все вызовы (`MCPBridge()`, `ReviewPostContext(...)` и т.д.) в `ChatViewModel.swift` и
`Chat/AgentFSM/ChatViewModel+AgentRun.swift` резолвятся как прежде. В `ChatViewModel.swift` на месте
типа остаётся только хранимое свойство/использующие функции (extension не может хранить
свойства — комментарий модуля уже фиксирует это правило) с однострочной ссылкой на новый
файл вместо перенесённого doc-комментария.

Единственное вынужденное отклонение от «байт-в-байт»: `TurnOverrides` была `private struct`
внутри `ChatViewModel`. Swift ограничивает `private` объявлением и extensions **того же
файла**; `send()`/`startGeneration`/`regenerateLastAnswer`, использующие `TurnOverrides`,
остаются в `ChatViewModel.swift`, а тип теперь в другом файле — `private` компилятор не
пропустил бы. Модификатор снят (default `internal`, как у остальных пяти bridge-типов,
которые уже были internal). API `ChatViewModel` не меняется: `TurnOverrides` и раньше не
была `private(set)`/`public` наружу модуля, видимость расширилась только с «файл» до
«модуль», использование не изменилось ни строкой.

Новые файлы (все — только `extension ChatViewModel { ... }`, без прочей логики):
- `Sources/SecondBrain/Chat/MCPBridge.swift`
- `Sources/SecondBrain/Chat/ProjectToolsBridge.swift`
- `Sources/SecondBrain/Chat/ChatGitBridge.swift`
- `Sources/SecondBrain/Chat/ReviewPostContext.swift`
- `Sources/SecondBrain/Chat/RagToolBridge.swift`
- `Sources/SecondBrain/Chat/TurnOverrides.swift`

`ChatViewModel.swift`: 886 → 834 строки (-52; тела шести типов ушли, doc-комментарии на
местах использования свёрнуты в одну строку со ссылкой на файл).

## Отчёт тестов

Логики не менялось — новых тестов не требуется, прогонялся полный сьют.

`./scripts/build.sh` — чисто, без новых предупреждений (те же существующие warnings в
`ChatToolAssembly.swift`, не в объёме).
`./scripts/test.sh` — `Executed 1130 tests, with 0 failures (0 unexpected)` — то же число,
что после задачи 75; поведение не изменилось.

## Результат

Шесть вложенных типов `ChatViewModel` вынесены в отдельные файлы (namespace сохранён через
`extension`). Логика не менялась. `TurnOverrides` перестал быть `private` — вынужденно,
из-за файловой границы `private` в Swift; видимость расширилась до `internal` (модуль),
использование не изменилось. Build/test зелёные, 1130 тестов без изменений. `GO` с первого
круга — ревьюер подтвердил побайтовую идентичность перемещения и оправданность единственного
отклонения (`private` → `internal`).
