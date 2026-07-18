# 29 — Видимость модели и токенов

## Цель
Под каждым ответом видно, какая модель ответила и сколько токенов потрачено; пикер «Авто» показывает реальный выбор роутера; per-чат можно задать произвольную строку модели.

## Зависимости
08 (облачные провайдеры), 09 (Ollama), 12 (чат), 26 (OpenRouter/DeepSeek), 27 (индикация).

## Контекст (диагноз)
- Стриминг не запрашивал usage (OpenAI-совместимым нужен `stream_options.include_usage`; Ollama игнорировал eval-каунты done-строки; Gemini не читал usageMetadata из чанков) — токены показывались никогда.
- Usage tool-цикла считался (ToolUseLoop.Outcome.usage) и выбрасывался.
- «Авто» в пикере не показывал, какую модель выбрал роутер; ResolvedChatProvider не нёс providerID.
- Свою строку модели per-чат задать было нельзя (только дефолт провайдера).

## Объём работ
- [ ] `ChatStreamEvent {text|usage}`; stream всех провайдеров и моков переведён на события.
- [ ] OpenAI: stream_options.include_usage + usage в чанке (финальный с choices:[]); Ollama: eval-каунты done-строки; Gemini: usageMetadata из чанков.
- [ ] `ResolvedChatProvider` + providerID/displayName; `MessageMetrics` + providerID/providerName/model (migration-safe); finishGeneration пишет usage+модель; tool-путь передаёт outcome.usage.
- [ ] metricsLine «Провайдер · модель · время · токены» + тултип с разбивкой; «Авто → DisplayName · model» в пикере.
- [ ] «Своя модель…» — редактор per-чат (провайдер + произвольная модель), поповер на корне detail.
- [ ] Тесты.

## Вне объёма
- Индикатор стоимости (бэклог п. 13 — токены теперь есть, цены нет).
- Флаг отключения stream_options для экзотических OpenAI-совместимых endpoint'ов (добавим по факту жалобы).

## Критерии приёмки
- `swift build` и `swift test` зелёные.
- Вживую: под ответом строка «DeepSeek · deepseek-chat · X с · N ток.»; пикер в «Авто» показывает реальную модель; «Своя модель…» сохраняет произвольную строку.

## Результат

Сделано (2026-07-17):
- **ChatStreamEvent**: `stream` возвращает поток событий; конформеры — OpenAIProvider (stream_options.include_usage, usage-чанк с пустыми choices разбирается до guard'а на дельту; покрывает OpenRouter/DeepSeek тем же клиентом), OllamaParsing.parseChatStreamLine → (delta, done, usage) из prompt_eval_count/eval_count, GeminiProvider — usageMetadata из чанков (последний выигрывает), MockChatProvider (+streamUsage) и 6 тестовых провайдеров.
- **ChatViewModel**: стрим-цикл switch по событиям; tool-путь берёт `outcome.usage` (фикс выбрасывания); `finishGeneration(duration:usage:resolved:error:)` пишет полные метрики.
- **Метрики**: `MessageMetrics` + providerID/providerName/model (decodeIfPresent — старый chats.json грузится, тест миграции); `ResolvedChatProvider` + providerID/displayName (обе ветки роутера + per-чат override); metricsLine «Провайдер · модель · 1.2 с · N ток.» + тултип «промпт/ответ».
- **«Авто → …»**: `resolvedAutoDescription` в VM, тайтл пикера показывает реальный выбор роутера (обновляется по availabilityTick).
- **«Своя модель…»**: пункт в пикере → `ChatModelEditor` (Picker провайдеров с пометками недоступности + TextField модели + «Сбросить на дефолт»); поповер якорится к корню detail — смена модели перерисовывает тулбар и убила бы якорь на кнопке (урок задачи 24).
- **Тесты** (+8, всего 649 зелёные): OpenAI-фикстура с usage-чанком и stream_options-энкодинг, Ollama done-строка (полные/частичные каунты), usage стрима → метрики с моделью (ScriptedChatProvider), usage tool-цикла суммируется (37 ток.), миграция старого metrics-JSON, providerID/displayName в обеих ветках резолва, resolvedAutoDescription.