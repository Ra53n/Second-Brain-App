# 07 — Абстракция LLM-провайдеров

## Цель
Единый слой доступа к моделям: протоколы для чата/транскрипции/эмбеддингов, реестр провайдеров, роутинг «функция приложения → провайдер+модель», безопасное хранение ключей.

## Зависимости
01.

## Контекст
Фундамент для всего ИИ в приложении. Требование пользователя: для каждой функции (транскрипция, summary встречи, чат, эмбеддинги) можно выбрать свою модель — локальную или облачную — и легко сравнивать провайдеров. Эталон: `Providers.swift` (enum провайдеров, endpoints, KeyStore) и `DeepSeekClient.swift` (immutable struct, async/await, DTO, LocalizedError) в MA.

## Объём работ
- [ ] `LLM/ProviderProtocols.swift`:
  - `ChatProvider`: `send(messages, settings) async throws -> ChatResult` + стриминговый вариант `stream(...) -> AsyncThrowingStream<String, Error>`;
  - `TranscriptionProvider`: `transcribe(audioURL, language?, hints?) async throws -> Transcript` (сегменты с таймкодами, если провайдер отдаёт);
  - `EmbeddingProvider`: `embed(texts) async throws -> [[Float]]`.
- [ ] `LLM/ProviderRegistry.swift`: известные провайдеры (id, имя, какие протоколы поддерживает, нужен ли ключ), их доступность (ключ есть / рантайм запущен).
- [ ] `LLM/FunctionRouting.swift`: enum функций приложения (`transcription`, `meetingSummary`, `chat`, `embedding`, `noteFiling`) → назначенный провайдер+модель; Codable, персистентно (паттерн ChatStore); дефолты и валидация «назначенный провайдер недоступен».
- [ ] `LLM/KeyStore.swift`: ключи в Keychain (kSecClassGenericPassword, account = provider id) + env-fallback (`SECONDBRAIN_OPENAI_KEY` и т.п., env приоритетнее — удобно для разработки). У MA ключи в файлах — здесь осознанное отличие, Keychain безопаснее.
- [ ] Общие DTO/ошибки: `LLMError: LocalizedError` (нет ключа, bad status, пустой ответ, недоступен рантайм), `ChatMessageDTO`, usage-метрики (порт из MA).
- [ ] Мок-провайдеры для тестов (`MockChatProvider` с канированными ответами, детерминированный `HashingEmbedder` — порт из RagEmbedding.swift MA).

## Вне объёма
Конкретные облачные реализации (08), Ollama/WhisperKit (09, 10), UI настроек (17 — но структуры данных должны быть готовы для него).

## Критерии приёмки
- Тесты: роутинг (назначение/чтение/дефолты/недоступный провайдер), сериализация и миграция конфига роутинга, KeyStore на тестовом Keychain-сервисе (запись/чтение/удаление; env-приоритет), DTO round-trip.
- `swift build` без предупреждений в новом коде.

## Подсказки
- Протоколы проектируй по потребителям: задача 11 (транскрипция+summary), 12 (чат+стриминг), 13 (эмбеддинги). Загляни в эти файлы задач, чтобы не пришлось ломать сигнатуры.
- Стриминг у MA отсутствует (осознанно) — но нам он нужен для чата; SSE-парсинг будет в задаче 08, здесь только сигнатура.
- Keychain без сторонних обёрток: SecItemAdd/CopyMatching/Update/Delete, ~50 строк.
