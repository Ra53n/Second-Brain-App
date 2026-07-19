# Задача 43: понятный выбор папки для заметки встречи

## Цель

Пользователь всегда видит и контролирует, в какую папку ляжет заметка встречи:
меню папок vault вместо свободного текстового поля, предвыбор его папки по
умолчанию, предложение ИИ — отдельной строкой (можно применить или
игнорировать), галочка «запомнить как папку по умолчанию», чип с текущей
папкой в статус-строке раздела.

## Зависимости

06 (запись), 11 (пайплайн встречи), 17 (настройки), 41 (редизайн вкладки,
статус-строка).

## Объём

1. Чистая модель `MeetingFolderPicker` (Meetings/MeetingFolderPicker.swift):
   normalize, menuItems (папки vault + extras с дедупом), preselected
   (confirmed > дефолт настроек > предложение ИИ > Meetings/YYYY-MM),
   aiSuggestion, settingsSelection, chipTitle.
2. `MeetingsViewModel`: `vaultFolderPaths()` + static `relativeFolderPaths`
   (извлечено из замыкания пайплайна, одно место истины);
   `confirmTitle(_:folder:rememberAsDefault:)` — сохранение дефолта
   через `MeetingSettingsStore.update` до запуска filing.
3. Диалог `TitleConfirmationView`: меню папок + «Другая или новая папка…»
   (свободный ввод, папка создастся автоматически), строка «ИИ предлагает: X»
   с кнопкой «Применить», Toggle «Запомнить как папку по умолчанию»,
   дизейбл «Создать заметку» при пустой папке.
4. Settings → «Встречи»: пикер папки («Штатная (Meetings/YYYY-MM)» + папки
   vault + «Другая…») вместо TextField; значение вне списка открывается
   в custom-режиме.
5. Чип статус-строки: «Папка: <дефолт или Meetings/ГГГГ-ММ>» → клик открывает
   Settings → «Встречи».

## Вне объёма

- Поиск/фильтр по меню папок (большие vault — компромисс как в «Переместить в…»).
- Древовидный NSOutlineView-пикер.
- Изменения промпта, parseSummaryResponse и resolveFolder — поведение ИИ
  не менялось.

## Критерии приёмки

- `swift build` и `swift test` зелёные; новая логика покрыта
  MeetingFolderPickerTests (normalize/menuItems/preselected/aiSuggestion/
  settingsSelection/chipTitle + relativeFolderPaths на temp-дереве).
- Смоук в собранном приложении: меню папок в настройках показывает реальные
  папки vault, чип в статус-строке, deep-link чипа.

## Результат

Сделано по плану; все пункты объёма реализованы.

- Новые файлы: `Sources/SecondBrain/Meetings/MeetingFolderPicker.swift`,
  `Tests/SecondBrainTests/MeetingFolderPickerTests.swift` (11 тестов).
- Изменены: `MeetingsViewModel` (vaultFolderPaths/relativeFolderPaths,
  rememberAsDefault в confirmTitle), `MeetingsPane` (диалог + чип «Папка: …»),
  `SettingsViews` (пикер папки в MeetingsSettingsTab).
- Задача планировалась как №42, но номер заняла параллельная задача
  (42-notes-breadcrumb) — оформлена как 43.
- Смоук: пикер в Settings показывает все папки живого vault полными путями,
  чип и deep-link работают. Диалог оформления проверен юнитами (UI-паттерн
  меню идентичен настройкам); полный прогон пайплайна не гонялся — у
  пользователя уже есть рабочий Deepgram, следующая реальная встреча покажет
  диалог с новым пикером.
- Агентам следующих задач: список папок vault для UI берите через
  `MeetingsViewModel.vaultFolderPaths()` (VaultManager приватен); чистая
  логика меню/предвыбора — в `MeetingFolderPicker`, добавляйте кейсы туда
  и покрывайте тестами.
