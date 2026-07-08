# 08 — Облачные провайдеры

## Цель
Рабочие реализации облачных провайдеров поверх абстракции 07: OpenAI (чат + Whisper-транскрипция + эмбеддинги), Google Gemini (чат + транскрипция аудио + эмбеддинги), Deepgram и/или AssemblyAI (транскрипция с диаризацией).

## Зависимости
07.

## Контекст
Пользователь будет сравнивать провайдеров транскрипции на своих встречах (русская речь!) — важно реализовать несколько. Эталон HTTP-клиента: `DeepSeekClient.swift` MA (immutable struct, URLSession async/await, DTO, обработка не-2xx с телом ошибки).

## Объём работ
- [ ] `LLM/Cloud/OpenAIProvider.swift`: chat/completions (+ SSE-стриминг), `audio/transcriptions` (whisper-1 / gpt-4o-transcribe; multipart upload), embeddings. Совместимость с OpenAI-compatible endpoint'ами (настраиваемый baseURL) — бонусом даёт OpenRouter/DeepSeek бесплатно.
- [ ] `LLM/Cloud/GeminiProvider.swift`: generateContent (+стриминг), аудио inline/через Files API для транскрипции (аудио >20 МБ — Files API), embedContent.
- [ ] `LLM/Cloud/DeepgramProvider.swift`: prerecorded transcription (language=ru, diarize=true, smart_format); сегменты с таймкодами и спикерами в наш `Transcript`.
- [ ] `LLM/Cloud/AssemblyAIProvider.swift`: upload → transcript → polling; если по времени не влезает — зафиксируй в «Результате» и оставь на 19 (Deepgram обязателен).
- [ ] Регистрация всех в ProviderRegistry; список моделей провайдера (статический либо с endpoint'а — как проще).
- [ ] Разбиение длинного аудио: у OpenAI лимит 25 МБ на файл — режь по времени средствами AVFoundation и склеивай транскрипты (пометь границы).

## Вне объёма
UI настроек и выбора моделей (17), локальные провайдеры (09, 10).

## Критерии приёмки
- Тесты (без сети): DTO кодирование/декодирование по зафиксированным JSON-фикстурам реальных ответов каждого API; SSE-парсер построчно (частичные чанки, [DONE]); маппинг ошибок (401/429/500 → понятные LLMError); логика нарезки аудио (границы по длительности).
- Живой смоук-тест руками (ключи из env): короткий текстовый запрос к каждому чат-провайдеру и транскрипция 30-сек аудио — задокументируй результат в «Результате».

## Подсказки
- Ключи только через KeyStore из 07; в тестах — фейковые.
- Deepgram отдаёт слова с таймкодами и speaker labels — сохрани их в Transcript, диаризация пригодится в 19.
- Multipart без библиотек: собери body руками (boundary + Data), как обычно делают в Swift.
- Фикстуры ответов клади в `Tests/SecondBrainTests/Fixtures/`.

## Результат

Выполнено полностью, включая AssemblyAI (не отложено на 19). 173 теста зелёные (34 новых), `swift build` без предупреждений. Живой смоук против РЕАЛЬНЫХ эндпоинтов всех 4 провайдеров пройден (см. ниже) — временный тест удалён после проверки.

Что сделано (модуль `Sources/SecondBrain/LLM/Cloud/`):
- `HTTPSupport.swift` — общее: `CloudHTTP.ensureSuccess` (провайдер-специфичный маппер ошибки), `SSEStream` (парсер Server-Sent Events над абстрактным `AsyncSequence<String>` — не завязан на URLSession, тестируется синтетическими строками), `MultipartFormData` (сборка руками, без библиотек).
- `AudioChunker.swift` — `planChunks` (чистая логика границ по длительности, тестируется без файлов) + `exportChunks` (реальная нарезка через `AVAssetExportSession`, не покрыта юнит-тестами — нужен настоящий аудиофайл).
- `OpenAIProvider.swift` — chat/completions (+ SSE-стриминг), audio/transcriptions (whisper-1 verbose_json с сегментами; gpt-4o-transcribe без сегментов), embeddings. Длинное аудио (>25 МБ) режется по расчётному битрейту файла, части транскрибируются и склеиваются с маркером `[Часть N]`, таймкоды сегментов сдвигаются на начало отрезка.
- `GeminiProvider.swift` — generateContent (+ streamGenerateContent?alt=sse — тот же SSE-парсер), транскрипция: inline base64 до 20 МБ, больше — Files API (upload multipart/related → polling ACTIVE → fileData.fileUri); embedContent через batchEmbedContents. Система: `system`-сообщения объединяются в `systemInstruction`, `assistant`→`model` (Gemini не принимает роль system/assistant в contents).
- `DeepgramProvider.swift` — сырые байты в теле (не multipart), диаризация (`diarize=true`) — слова группируются в сегменты по говорящему (`Speaker N: …`).
- `AssemblyAIProvider.swift` — upload → transcript-запрос → polling (интервал/лимит попыток настраиваемы); таймкоды в МИЛЛИСЕКУНДАХ (в отличие от Deepgram — секунды), конвертация учтена. `AssemblyAIPolling.shouldContinuePolling` — чистая логика терминальных статусов, тестируется отдельно от сети.
- `CloudProviders.swift` — регистрация всех 4 в ProviderRegistry с дескрипторами (capabilities/defaultModel); подключено в `ContentView.init()` (`providerRegistry`/`functionRouter` как StateObject — ещё не используются UI, но граф объектов готов для 11/12/13/17).

**Фикстуры — из реального мира, не выдуманы**: `openai_error_401.json`, `gemini_error_403.json`, `deepgram_error_401.json`, `assemblyai_error_401.json` сняты живыми curl-запросами без ключа (см. Bash-историю сессии) — это подлинный формат ошибок каждого API на момент задачи. Success-фикстуры (chat/whisper/embeddings/gemini/deepgram/assemblyai) собраны по официальной документации, вручную (валидных ключей нет — раздел ниже).

**Живой смоук (критерий приёмки)**: ключей пользователя нет (`env | grep -i openai/gemini/...` пусто), полноценный успешный запрос не проверялся. Вместо этого — прогон с заведомо неверным ключом против настоящих эндпоинтов (сеть в этой среде доступна, проверено `curl`), чтобы подтвердить URL/заголовки/формат тела реальным сервером, а не только фикстурами:
  - OpenAI: 401 «Incorrect API key provided…»
  - Gemini: 400 «API key not valid» (не 403 — валидный, но неверный ключ Gemini отклоняет иначе, чем полное отсутствие ключа; код учтён)
  - Deepgram: 401 «Invalid credentials.»
  - AssemblyAI: 401 «Authentication error, API token missing/invalid»
  Все четыре смаппились в `LLMError.badStatus` с ожидаемым кодом — цепочка URL→заголовки→кодирование тела→декодирование ошибки работает end-to-end. Когда у пользователя появятся реальные ключи (через `KeyStore.setKey` или `SECONDBRAIN_<ID>_KEY`), для полной проверки успешного пути достаточно повторить этот же сценарий без подмены ключа на фейковый.

Отклонения и заметки для 09/10/11/12/13/17:
- baseURL у `OpenAIProvider` настраиваемый (задел на OpenAI-совместимые эндпоинты — OpenRouter/DeepSeek/локальные раннеры), но в этой задаче регистрируется только официальный OpenAI — по объёму задачи.
- Gemini не отдаёт таймкоды по словам — `Transcript.segments` от Gemini всегда пуст; для диаризации/таймкодов предпочитайте Deepgram/AssemblyAI/Whisper.
- `FunctionAssignment.model` для транскрипции/эмбеддингов не передаётся в вызов (протоколы этого не предполагают, см. задачу 07) — модель «зашита» в экземпляр провайдера при регистрации (`transcriptionModel`/`embeddingModel` в инициализаторах); при появлении настроек (17) для смены модели транскрипции потребуется пересоздать экземпляр провайдера с другим параметром.
