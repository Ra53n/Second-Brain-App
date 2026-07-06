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
