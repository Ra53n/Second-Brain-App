# Задача 69: `FrontmatterParser` теряет пустой frontmatter при сериализации

## Тип

баг

## Модель

haiku

## Цель

`FrontmatterParser` (`Sources/SecondBrain/Links/FrontmatterParser.swift:64`) не делает
round-trip для пустого frontmatter — блок `---\n---\n` теряется при повторной
сериализации (найдено тестами задачи 58, `tasks/BACKLOG.md` п.32). Практическое следствие:
заметка с пустым frontmatter-блоком (например, пользователь оставил заготовку под будущие
поля) при программной правке через приложение молча теряет эту заготовку.

## Зависимости

Нет.

## Объём

1. `Sources/SecondBrain/Links/FrontmatterParser.swift:64` — сериализация: пустой словарь
   frontmatter должен давать на выходе тот же пустой блок `---\n---\n`, а не отсутствие
   блока вовсе (round-trip: parse → serialize → parse даёт эквивалентный результат).
2. Тест round-trip именно на пустой frontmatter.

## Вне объёма

Изменение формата frontmatter, парсинг вложенных YAML-структур.

## Критерии приёмки

- [x] `parse` → `serialize` на файле с пустым frontmatter-блоком возвращает эквивалентный
      блок, не теряет его.
- [x] Новый тест в `Tests/SecondBrainTests/FrontmatterParserTests.swift` (или где лежат
      существующие тесты парсера) покрывает этот кейс.
- [x] `./scripts/build.sh` и `./scripts/test.sh` зелёные, число тестов не уменьшилось.

## Отчёт тестов

**Что нашёл:** `FrontmatterParser.serialized()` на строке 64 используя `guard !entries.isEmpty else { return body }` теряет маркеры `---\n---\n` для пустого фронтматтера, так как парсер не различает "нет frontmatter" (entries=[]) от "пустой frontmatter-блок" (entries=[], но были маркеры).

**Что починил:**
- `FrontmatterDocument`: добавлен флаг `hasEmptyFrontmatterBlock: Bool = false` (строка 42)
- `FrontmatterParser.parse()`: проверяется `fieldLines.isEmpty` и устанавливается флаг (строка 121)
- `serialized()`: проверяет флаг при `entries.isEmpty` — если флаг=true, выдаёт `"---\n---\n" + body`, иначе только `body` (строка 71)

**Что проверил:**
- `./scripts/build.sh`: успешно (4.99 сек)
- `./scripts/test.sh`: 1100 тестов, 0 падений (было 1098 до задачи; +3 новых теста, −1 дубль-тест
  после ревью — см. правки по замечаниям ниже)
- Регрессионный тест `testEmptyFrontmatterBlockRoundTripsCorrectly()`: проверяет, что parse →
  serialize → parse даёт идентичный результат (закрывает баг задачи)
- Новые тесты: `testDocumentWithoutFrontmatterDoesNotGetEmptyBlockMarkers()` (без фронтматтера
  флаг=false), `testAddingFieldToEmptyFrontmatterBlockPreservesFrontmatter()` (edge case:
  добавление поля к пустому блоку)

**Правки по NO-GO первого круга ревью:**
- Удалён дубль-тест `testEmptyFrontmatterBlockDoesNotRoundTripByteExact()` — полностью
  перекрыт `testEmptyFrontmatterBlockRoundTripsCorrectly()` под верным именем (число тестов
  1101 → 1100, ожидаемо).
- Наслоённые устаревшие комментарии (206–220) заменены одним актуальным.
- В `FrontmatterParser.swift` к полю `hasEmptyFrontmatterBlock` добавлена строка doc-комментария:
  флаг умышленно не участвует в mutation-пути (subscript), отражает только состояние на момент
  parse — асимметрия с `testEmptyFrontmatterSerializesToBodyOnly` (`LinksTests.swift:259`)
  задокументирована, не признана дефектом.

## Результат

`FrontmatterDocument` получил флаг `hasEmptyFrontmatterBlock`, различающий «нет frontmatter»
от «пустой frontmatter-блок» — `serialized()` восстанавливает маркеры `---\n---\n` для второго
случая. Два круга ревью: первый NO-GO — дублирующий тест с вводящим в заблуждение именем,
наслоённые устаревшие комментарии, недокументированная асимметрия parse/mutation-путей. Все
три устранены. Второй круг — `GO`.

Асимметрия parse/mutation осталась осознанно (флаг не обновляется через subscript) —
задокументирована doc-комментарием у поля, не является дефектом в рамках этой задачи.
