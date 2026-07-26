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

- [ ] `parse` → `serialize` на файле с пустым frontmatter-блоком возвращает эквивалентный
      блок, не теряет его.
- [ ] Новый тест в `Tests/SecondBrainTests/FrontmatterParserTests.swift` (или где лежат
      существующие тесты парсера) покрывает этот кейс.
- [ ] `./scripts/build.sh` и `./scripts/test.sh` зелёные, число тестов не уменьшилось.
