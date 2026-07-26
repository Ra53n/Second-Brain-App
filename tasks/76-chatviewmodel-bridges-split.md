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

- [ ] Шесть новых файлов созданы, `ChatViewModel.swift` уменьшился на соответствующее число
      строк, вложенность типов (namespace) сохранена.
- [ ] Поведение не изменилось: существующие тесты на `ChatViewModel`/агентский FSM проходят
      без изменений.
- [ ] `./scripts/build.sh` и `./scripts/test.sh` зелёные, число тестов не уменьшилось.
