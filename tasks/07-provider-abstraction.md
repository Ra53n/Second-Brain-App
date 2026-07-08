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

## Результат

Выполнено полностью. 139 тестов зелёные (43 новых), `swift build` без предупреждений в новом коде.

Что сделано (модуль `Sources/SecondBrain/LLM/`):
- `ProviderProtocols.swift` — `ChatProvider` (send + stream через `AsyncThrowingStream`), `TranscriptionProvider`, `EmbeddingProvider` (+ `embedOne`); DTO `ChatMessageDTO`, `ChatSettings`, `ChatUsage`, `ChatResult`, `Transcript`/`TranscriptSegment`; `LLMError: LocalizedError`.
- `ProviderRegistry.swift` — `ProviderID` (строковый, не enum-кейсы: новые провайдеры 08/09/10 регистрируются без правки этого файла), `ProviderCapability`, `ProviderDescriptor` (id/имя/способности/isLocal/defaultModel), `@MainActor ObservableObject` реестр с `register()`/резолвом реализаций по id/`isAvailable()`.
- `KeyStore.swift` — Keychain (kSecClassGenericPassword, ~70 строк голого Security.framework, без обёрток) + env-fallback с приоритетом env (`SECONDBRAIN_<ID>_KEY`). Осознанное отличие от MA (там ключи в файлах).
- `FunctionRouting.swift` — `AppFunction` (5 функций из задачи, `requiredCapability` на каждую), `FunctionAssignment`, `FunctionRoutingConfig` (Codable словарь по `rawValue`-ключу — устойчив к будущим полям), `FunctionRoutingStore` (паттерн ChatStore: JSON в Application Support, atomic write, `.corrupt.json`), `FunctionRouter` (`@MainActor ObservableObject`) — резолв явного назначения с валидацией (провайдер существует, поддерживает способность, доступен) и прозрачный дефолт (первый доступный провайдер способности с `defaultModel`).
- `MockProviders.swift` — `MockChatProvider` (канонированные ответы по кругу, конфигурируемые ошибка/задержка, стриминг по словам, лог полученных сообщений), `MockTranscriptionProvider`, `HashingEmbedder` (порт из MA RagEmbedding.swift — детерминированный bag-of-words, без сети).

Важные решения и заметки для 08/09/10/11/12/13/17:
- **FunctionAssignment.model** используется по-разному по способностям: для чата уходит в `ChatSettings.model` (один провайдер обслуживает много моделей); для транскрипции/эмбеддингов протокол НЕ принимает model-параметр (сигнатуры зафиксированы 1-в-1 по тексту задачи) — модель обычно «зашита» в конкретный экземпляр провайдера при регистрации (09/10), а поле в assignment — для отображения в UI настроек. Задокументировано в файловых заголовках.
- **Дефолт роутинга без хардкода провайдеров**: `defaultAssignment` берёт первый ЗАРЕГИСТРИРОВАННЫЙ доступный провайдер способности с непустым `defaultModel` — до задачи 08 реестр пуст, `resolve*` вернёт nil, и это ожидаемо (нечего резолвить).
- **isAvailable для локальных провайдеров** — опциональный closure, регистрируемый вызывающим (задачи 09/10 передадут реальную проверку живого процесса); без него локальный провайдер считается доступным всегда — не блокирует разработку до появления LocalRuntimeManager.
- KeyStore.service — `var`, не `let`: тесты подменяют на уникальный сервис (не трогают реальные ключи пользователя). Прогон на реальном Keychain не потребовал разрешающих диалогов (SecItemAdd/CopyMatching для generic password, созданных этим же процессом, проходят молча).
- Протоколы НЕ помечены `AnyObject`/`Sendable` — конкретные HTTP-клиенты (задача 08) по CONVENTIONS.md должны быть immutable struct'ами; тесты сравнивают идентичность мок-провайдеров (классов) через `as AnyObject`.
