# Задача 77: разбить `SettingsViews.swift` по вкладкам

## Тип

рефакторинг

## Модель

sonnet

## Цель

`Sources/SecondBrain/Settings/SettingsViews.swift` (830 строк) содержит 5+ независимых
вкладок настроек (`GeneralSettingsTab`, `ProvidersSettingsTab`, `ModelsSettingsTab`,
`MeetingsSettingsTab`, `ToolsSettingsTab`) в одном файле. Естественная граница разбиения —
по вкладке; правка одной вкладки не должна требовать чтения остальных четырёх.

## Зависимости

Нет.

## Объём

1. `ast-index outline Sources/SecondBrain/Settings/SettingsViews.swift` — свериться с
   точными границами каждой вкладки.
2. Вынести каждую вкладку в свой файл: `GeneralSettingsTab.swift`, `ProvidersSettingsTab.swift`,
   `ModelsSettingsTab.swift`, `MeetingsSettingsTab.swift`, `ToolsSettingsTab.swift` (плюс
   любые общие вспомогательные View, используемые несколькими вкладками — оставить в
   `SettingsViews.swift` как общий файл, а не размножать копиями).
3. Никакой правки логики.

## Вне объёма

Изменение состава/поведения вкладок, добавление новой вкладки.

## Критерии приёмки

- [ ] 5 новых файлов созданы по числу вкладок, `SettingsViews.swift` содержит только общие
      вспомогательные типы (или пуст/удалён, если общего не осталось).
- [ ] Поведение не изменилось: `./scripts/ui.sh` смоук настроек (задача 47 упоминает
      `ToolsSettingsTab` — если есть готовый сценарий смоука настроек, прогнать его) проходит.
- [ ] `./scripts/build.sh` и `./scripts/test.sh` зелёные, число тестов не уменьшилось.
