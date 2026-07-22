# Модуль Meetings — правила

FSM встречи: запись → транскрипция → summary → заметка в vault. Главная фича продукта;
ошибка здесь стоит пользователю потерянной встречи.

## Что здесь живёт

- `MeetingModels` — доменные типы, `MeetingFSM.transitions` (таблица переходов),
  `MeetingRunStatus`, `MeetingError`.
- `MeetingPipeline` — оркестратор этапов: транскрипция всех дорожек, summary, filing.
- `MeetingStore` / `MeetingSettings` — персистентность прогонов и настроек раздела.
- `MeetingPrompts` — структурный промпт `[TRANSCRIPT]`/`[VAULT_FOLDERS]`/`[USER_RULES]`
  и разбор ответа по маркерам `TITLE:`/`FOLDER:`/`SUMMARY:`.
- `MeetingNoteWriter` — запись .md в vault; `MeetingFolderPicker` — чистая логика выбора
  папки; `TranscriptionRoute` — чип провайдера в статус-строке.
- `MeetingsViewModel` / `MeetingsPane` — состояние и UI раздела.

## Инварианты

1. **Переходы — только по `MeetingFSM.transitions`**; `persistNow()` синхронно после
   каждого. Зависшие `running` на старте → `paused`, resume идемпотентен.
2. **Настройки пишутся только через `MeetingSettingsStore.update`** (load-modify-save):
   файл `meeting_settings.json` редактируют два UI (раздел и Settings), прямая запись
   стирает чужие поля — это уже был баг, есть регрессионный тест.
3. **Папку от LLM валидируем по реальному дереву vault**, фолбэк — `Meetings/YYYY-MM`.
   Модель может предложить несуществующую или опасную папку.
4. **Источник записи по умолчанию** — только через `MeetingSettings.resolvedDefaultSource`:
   любой источник с системным звуком деградирует в микрофон на macOS < 14.4. Settings и
   ViewModel обязаны вести себя одинаково.
5. Длинный транскрипт идёт map-reduce чанками ~24 тыс. символов — не отправляй целиком.
6. Текст дорожки для summary собирается из сегментов (`TrackTranscript.promptText`), чтобы
   метки диаризации «Speaker N:» дошли до модели.

## Как тестируем

- Таблица переходов — исчерпывающе по всем парам состояний (`MeetingFSMTests`).
- Пайплайн — на моках провайдеров, включая падение шага и ретрай (`MeetingPipelineTests`).
- Промпты и разбор ответа — round-trip и битые ответы модели (`MeetingPromptsTests`).
- Запись заметки — на temp-vault (`MeetingNoteWriterTests`), живой vault не трогаем.
- Выбор папки — чистая логика в `MeetingFolderPickerTests`, UI не тестируем.

## Частые ошибки прошлых задач

- Провайдер транскрипции выбирается напрямую, минуя `FunctionRouter` → пользовательское
  назначение и фолбэки перестают работать (задача 41 чинила именно это).
- Summary падает, если у провайдера не скачана модель — цепочка кандидатов
  (`resolveChatProviders`) существует, используй её, а не первого попавшегося.
- Средняя колонка раздела без явной ширины превращается в вертикальную кашу:
  `.navigationSplitViewColumnWidth(min: 360, ideal: 480, max: 720)`.

## Куда не лезть

Сама запись звука — модуль `Audio/`; провайдеры и роутинг — `LLM/`; операции с файлами
vault — `Vault/`.
