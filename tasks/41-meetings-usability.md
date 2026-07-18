# Задача 41: надёжная транскрипция, дефолт «оба входа» и редизайн вкладки «Встречи»

## Цель

Вкладкой «Встречи» можно пользоваться: транскрипция собственных записей (.m4a)
не падает, диаризация доходит до саммари, запись по умолчанию идёт на оба входа,
провайдер транскрипции виден и переключается прямо в разделе, а всё
настраиваемое (правила раскладки, папка, статусы разрешений) живёт в Settings.

## Зависимости

06 (запись), 08 (облачные провайдеры), 11 (пайплайн встречи), 17 (настройки),
32/33 (доступность провайдеров, изоляция routing-тестов).

## Объём

1. **Фиксы транскрипции**:
   - `OpenAIProvider`: MIME по расширению файла (`mimeType(for:)`) вместо
     захардкоженного `audio/mpeg` — записи .m4a уходили с неверным типом;
   - `DeepgramProvider`: параметр `model=nova-2` в query (`queryItems(...)`) —
     без него Deepgram использовал базовую модель вместо заявленной в
     дескрипторе, и качество на русском страдало;
   - `MeetingContext.combinedTranscriptText`: текст дорожки собирается из
     сегментов (`TrackTranscript.promptText`) — метки «Speaker N:» доходят
     до summary-промпта; фолбэк — fullText.
2. **Дефолт «оба входа»**: `MeetingSettings.resolvedDefaultSource(systemAudioSupported:)`
   — nil → `.both`, деградация в `.microphone` на macOS < 14.4; применён в
   `MeetingsViewModel` и `MeetingsSettingsTab`.
3. **Переключатель провайдера транскрипции**: `TranscriptionRoutePresenter`
   (Meetings/TranscriptionRoute.swift) поверх `FunctionRouter` — чип
   «Транскрипция: X / Авто (X) / нет провайдера» в статус-строке раздела,
   меню выбора (недоступные видны задизейбленными), «Авто» снимает назначение.
   `FunctionRouter.defaultAssignment` открыт (был private).
4. **Осмысленные ошибки**: `MeetingErrorNavigation.settingsTab(forErrorText:)`
   — алерт «Пайплайн встречи» при ошибках «нет провайдера» получает кнопку
   «Открыть настройки» (deep-link через SettingsTabRouter).
5. **Редизайн MeetingsPane**: одна строка «Записать + компактное меню
   источника + название»; предупреждения о разрешениях — только когда реально
   мешают; баннер «нет провайдера транскрипции» с кнопками в настройки;
   нижняя статус-строка в стиле settingsBar чата (провайдер транскрипции +
   «Правила и папка…»). Правила раскладки и полные статусы разрешений —
   только в Settings → «Встречи» (секция «Разрешения» добавлена).

## Вне объёма

- Импорт внешних аудио/видео файлов (MP4 из Zoom и т.п.) — пользователь
  подтвердил, что не нужен.
- Реалтайм-микс дорожек, UI диаризации в заметке (задача 19/бэклог).
- Новые провайдеры транскрипции.

## Критерии приёмки

- `swift build` и `swift test` зелёные; новые тесты покрывают mimeType,
  queryItems, combinedTranscriptText, resolvedDefaultSource, презентер
  и маппинг ошибок (MeetingsUsabilityTests.swift).
- Тесты назначений роутинга — только через temp `storeURL` (регресс задачи 33
  недопустим).
- Смоук в собранном приложении: чип провайдера переключается, баннер и алерт
  ведут в настройки, дефолт источника — «Оба».

## Результат

Сделано по плану, все пункты объёма реализованы.

- Новые файлы: `Sources/SecondBrain/Meetings/TranscriptionRoute.swift`
  (презентер чипа + `MeetingErrorNavigation`),
  `Tests/SecondBrainTests/MeetingsUsabilityTests.swift` (25 тестов).
- Изменены: `OpenAIProvider` (mimeType), `DeepgramProvider` (model в query,
  `defaultModel` — единая константа с регистрацией), `MeetingModels`
  (`TrackTranscript.promptText`, `combinedTranscriptText` из сегментов),
  `MeetingSettings` (`resolvedDefaultSource`), `MeetingsViewModel`
  (хранит `functionRouter`, дефолт источника), `MeetingsPane` (редизайн +
  статус-строка + алерт с кнопкой настроек), `SettingsViews`
  (секция «Разрешения», дефолт источника «Оба»), `RecordingTypes`
  (`RecordingSource.systemImage`), `FunctionRouting`
  (`defaultAssignment` internal).
- Дополнительно по итогам смоука в собранном приложении: средней колонке
  раздела задана ширина `.navigationSplitViewColumnWidth(min: 360, ideal: 480,
  max: 720)` (ContentView) — дефолтные ~250 pt превращали панель в
  вертикальную кашу; баннер провайдера свёрстан вертикально (текст → кнопки),
  метаданные строки записи ограничены одной строкой (`lineLimit(1)`).
- Отклонения: helper дефолт-источника назван `resolvedDefaultSource` и
  деградирует ЛЮБОЙ источник с системным звуком (не только nil) на macOS
  < 14.4 — так settings-пикер и вью-модель ведут себя одинаково.
- Агентам следующих задач: статус-строка раздела «Встречи» переиспользует
  паттерн `settingsBar` чата (`.accessoryBar`, `.controlSize(.small)`);
  доступность провайдеров пересчитывается по `NSWindow.didBecomeKeyNotification`
  (тик `availabilityTick`). `PermissionRow` теперь internal — им пользуется
  Settings → «Встречи».
