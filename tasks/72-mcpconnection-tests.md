# Задача 72: тесты на `MCPConnection.swift`

## Тип

тест

## Модель

haiku

## Цель

`Sources/SecondBrain/MCP/MCPConnection.swift` реализует построчный JSON-RPC фрейминг по
stdio с ручной сборкой буфера и корреляцией по id — ноль тестов. Именно такая логика чаще
всего ломается на граничных случаях (частичное чтение, обрыв процесса посреди сообщения,
несовпадение id ответа).

## Зависимости

Нет.

## Объём

1. Изучить `MCPConnection.swift`: как устроен фрейминг (построчный/по длине), где
   происходит сборка буфера, как коррелируются запрос/ответ по id.
2. Написать `Tests/SecondBrainTests/MCPConnectionTests.swift` с инжектируемым транспортом
   (не реальный процесс — по антипаттерну 3 «сеть/процессы в тестах»): частичное сообщение
   в одном чтении, сообщение, разбитое на два чтения, ответ с неизвестным id, обрыв потока
   посреди JSON.

## Вне объёма

Изменение протокола MCP, `MCPManager`, `MCPServer`.

## Критерии приёмки

- [x] `Tests/SecondBrainTests/MCPConnectionTests.swift` покрывает минимум: частичное чтение,
      разбитое на два чтения сообщение, неизвестный id, обрыв потока.
- [x] Тесты не открывают реальный процесс/сеть — инжектируемый транспорт или мок.
- [x] `./scripts/build.sh` и `./scripts/test.sh` зелёные, число тестов не уменьшилось.

## Отчёт тестов

Чистое ядро stdio-фрейминга `MCPConnection` вынесено в `MCPFraming` (extractLines,
resolvePending) — `internal`, без `Process`, покрыто `Tests/SecondBrainTests/MCPConnectionTests.swift`
(7 тестов, `final class MCPConnectionTests`):

- `testExtractLinesPartialMessageInOneRead` — сообщение без `\n` не извлекается, остаётся в buffer.
- `testExtractLinesSplitAcrossTwoReads` — сообщение, разбитое на два чтения, собирается в одну строку.
- `testExtractLinesSkipsEmptyLines` — пустые строки (`\n\n`) пропускаются.
- `testExtractLinesBrokenStreamMidJSON` — обрыв потока посреди JSON: незавершённая строка не извлекается и не теряется молча (остаётся в buffer как есть).
- `testResolvePendingUnknownIdIgnored` — ответ с id, которого нет в `pending` (или пустой `pending`), молча отбрасывается без падения.
- `testResolvePendingHappyPathResolvesContinuation` — совпавший id резолвит continuation через `continuation.resume(returning:)` (проверено `withCheckedThrowingContinuation`).
- `testResolvePendingErrorPathThrowsRpcError` — `message.error` резолвит continuation через `continuation.resume(throwing: MCPError.rpc(...))` с правильными code/message.

Production-путь (`drainLines()`/`consume()`/`AsyncStream`) не менялся поведенчески —
только делегирует резку строк и корреляцию в `MCPFraming`; сам актор `MCPConnection`
(реальный `Process`, resume) вручную не тестируется — как и раньше, без живого MCP-сервера
сравнивать не с чем (см. `MCP/CLAUDE.md`).

Дыры: сам актор с реальным subprocess (handshake, notify, shutdown, gone-process race)
остаётся без юнит-тестов — вне объёма задачи, требует инжектируемого `Process`.

`./scripts/build.sh` — чисто. `./scripts/test.sh` — 1107 тестов (было ~1100), 0 падений.

## Результат

Чистое ядро stdio-фрейминга и корреляции по id вынесено из actor `MCPConnection` в
`enum MCPFraming` (extractLines/resolvePending), покрыто 7 тестами включая happy-path и
error-path резолва continuation. Первый круг ревью провалился по вине окружения — субагент
по ошибке отредактировал файлы в соседнем основном чекауте (`main`) вместо воркдира сессии,
диф пришлось восстанавливать вручную и переделывать с нуля; заодно на первом заходе не
хватало happy/error-path тестов и использовался самодельный `_test`-префикс вместо чистого
типа. Второй круг (в правильном воркдире, с правильным именованием и полным покрытием) —
`GO`.

Сам актор `MCPConnection` (реальный `Process`, handshake/shutdown) остаётся без юнит-тестов
— задокументировано в `MCP/CLAUDE.md` как осознанный пробел (нет инжектируемого `Process`,
не с чем сравнивать без живого сервера).
