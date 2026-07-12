# 10 — Локальная транскрипция (WhisperKit)

## Цель
Транскрипция на устройстве без облака: WhisperKit как ещё один `TranscriptionProvider`, со скачиванием whisper-моделей и выбором размера модели.

## Зависимости
07.

## Контекст
Пользователь знает, что локальная транскрипция слабее облачной, но хочет её как опцию (приватные встречи, оффлайн). WhisperKit (argmaxinc/WhisperKit, SPM-пакет) — Whisper на CoreML, оптимизирован под Apple Silicon, сам умеет качать модели с Hugging Face.

## Объём работ
- [ ] Добавить зависимость WhisperKit в Package.swift.
- [ ] `LocalRuntime/WhisperKitProvider.swift`: реализация `TranscriptionProvider` — загрузка модели (лениво, выгрузка по idle — освобождать память по аналогии с OllamaManager), транскрипция .m4a с сегментами и таймкодами, language hint (ru).
- [ ] `LocalRuntime/WhisperModels.swift`: список доступных моделей (tiny→large-v3 + turbo), скачивание с прогрессом, хранение в Application Support, удаление; рекомендация по умолчанию для Apple Silicon пользователя (large-v3-turbo или medium — проверь скорость).
- [ ] Регистрация в ProviderRegistry («локальный», ключ не нужен).
- [ ] UI: в разделе локальных моделей (из 09) — вкладка/секция Whisper-моделей с тем же UX скачивания.
- [ ] Прогресс транскрипции наружу (длинная встреча — минуты работы): колбэк с долей готового.

## Вне объёма
Пайплайн встречи (11), диаризация (WhisperKit её не делает — 19).

## Критерии приёмки
- Тесты: маппинг результата WhisperKit → наш Transcript (по фикстуре), логика выбора/хранения моделей, idle-выгрузка (инжектируемые часы).
- Ручная проверка: скачать модель через UI, транскрибировать 1-мин запись русской речи из задачи 06 — текст осмысленный; повторная транскрипция не перекачивает модель; после idle память процесса возвращается к базовой (модель выгружена).

## Подсказки
- WhisperKit качает с HF сам (`WhisperKit(model:)`) — но направь его кэш в наш Application Support, чтобы UI управления моделями видел файлы.
- Формат: WhisperKit ест 16кГц WAV внутри — он сам конвертит через AVFoundation, но проверь с нашим .m4a.
- Модель в памяти — гигабайты; выгрузка по idle обязательна (у нас ещё Ollama рядом живёт).

## Результат

Выполнено; `swift build` (debug и release) и `swift test` зелёные (435 тестов, +13 новых).

**Что сделано**:

- Package.swift: зависимость `argmaxinc/WhisperKit` from 0.9.0 (разрешилась в 0.18.0; тянет swift-transformers и др.).
- `LocalRuntime/WhisperModels.swift` — каталог вариантов (tiny → large-v3 + large-v3_turbo; рекомендация для Apple Silicon — **large-v3_turbo**: качество large при кратно большей скорости), хранение: downloadBase = `Application Support/SecondBrain/WhisperKit` (модели в `models/argmaxinc/whisperkit-coreml/openai_whisper-<вариант>`), скан установленного, удаление, размер на диске; маппинг `WhisperEngineOutput` → наш `Transcript` (трим, выброс пустых сегментов, битый end < start → nil).
- `LocalRuntime/WhisperKitProvider.swift` — `TranscriptionProvider`: движок за протоколом `WhisperEngine` (реальный адаптер `WhisperKitEngine` над `WhisperKit(config)`/`transcribe(audioPath:decodeOptions:callback:)`); ленивая загрузка при первой транскрипции, повторная НЕ пересоздаёт движок, смена варианта пересоздаёт; **idle-выгрузка** через ту же `IdleShutdownPolicy` из задачи 09 (таймер 60 с) — модель в RAM гигабайты; выбранный вариант персистентен (UserDefaults); прогресс транскрипции наружу (`@Published transcriptionProgress`, оценка по номеру 30-секундного окна против длительности файла); language hint передаётся в `DecodingOptions`.
- Регистрация: `LocalProviders.registerWhisper` — id "whisperkit", isLocal, `[.transcription]`; **доступен только когда скачана хоть одна модель** — иначе роутер молча запустил бы закачку гигабайтов с HF.
- UI: секции Whisper в LocalModelsPane (тот же UX, что Ollama): состояние движка в памяти + «Выгрузить сейчас», Picker активной модели, каталог со скачиванием (`WhisperKit.download(variant:downloadBase:progressCallback:)`, прогресс-бар, отмена), удаление с диска, размер.

**Тесты**: WhisperMappingTests (фикстура whisper_segments.json → Transcript, трим/пустые/битые сегменты), WhisperModelStorageTests (скан/удаление/размер/парсинг имён папок на temp-директориях), WhisperKitProviderTests (ленивая загрузка и переиспользование движка — фабрика вызвана 1 раз на 2 транскрипции; idle-выгрузка на инжектированных часах; перезагрузка при смене варианта; персистентность выбора; сброс состояния при ошибке фабрики).

**Ручная проверка не выполнялась** (нужны сеть до HF и Apple Silicon-время): скачать large-v3_turbo через UI → транскрибировать минутную русскую запись из задачи 06 → текст осмысленный; повторная транскрипция без перекачки; после простоя память процесса возвращается к базовой. Проверить, что WhisperKit прожёвывает наш .m4a (внутри конвертит через AVFoundation — должен).

**Агентам следующих задач**: 11 уже работает с Whisper через роутер (функция .transcription) — достаточно скачать модель и назначить провайдера; 17 — настройка idle-таймаута выгрузки; 19 — сравнение провайдеров транскрипции.
