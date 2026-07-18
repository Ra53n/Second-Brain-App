# 26 — Провайдеры OpenRouter и DeepSeek

## Цель
Пользователь работает через OpenRouter и DeepSeek (ключи есть) — добавить оба как чат-провайдеры: ключ в настройках, выбор в пикере модели чата и в роутинге, function calling для инструментов.

## Зависимости
08 (облачные провайдеры), 17 (настройки/ключи).

## Контекст
Оба API OpenAI-совместимы; OpenAIProvider уже задуман под это (настраиваемый baseURL — комментарий в заголовке файла), но id ключа зашит статически. Function calling у обоих работает через тот же OpenAI-формат → ToolCapableChatProvider достаётся бесплатно.

## Объём работ
- [ ] OpenAIProvider: инстансный `keyID` (дефолт — openai) для KeyStore/ошибок вместо статического Self.id.
- [ ] Регистрация в CloudProviders: OpenRouter (`https://openrouter.ai/api/v1`, дефолт `deepseek/deepseek-chat`) и DeepSeek (`https://api.deepseek.com/v1`, дефолт `deepseek-chat`), способность — только .chat.
- [ ] KeyVerifier: проверка ключа OpenRouter (`GET /api/v1/key`) и DeepSeek (`GET /v1/models`).
- [ ] Тесты: регистрация (capabilities/defaultModel/requiresKey), missingAPIKey несёт правильный id, KeyVerifier.request для новых провайдеров.

## Вне объёма
- Эмбеддинги/транскрипция через эти провайдеры (у DeepSeek нет; OpenRouter — бэклог при необходимости).
- Список моделей OpenRouter из API (модель вводится текстом в роутинге / дефолт per-чат).

## Критерии приёмки
- `swift build` и `swift test` зелёные.
- В Настройки → Провайдеры появляются OpenRouter и DeepSeek с полем ключа и «Проверить»; после сохранения ключа модель выбирается в чате и отвечает; инструменты работают.

## Результат

Сделано (2026-07-17):
- `OpenAIProvider.keyID` — инстансный id для KeyStore и текстов ошибок (дефолт «openai», обратная совместимость полная).
- `CloudProviders.registerAll`: OpenRouter (id `openrouter`, baseURL `https://openrouter.ai/api/v1`, дефолт-модель `deepseek/deepseek-chat`) и DeepSeek (id `deepseek`, baseURL `https://api.deepseek.com/v1`, дефолт-модель `deepseek-chat`) — оба только .chat, тот же клиент, function calling через существующее расширение ToolCapableChatProvider.
- KeyVerifier: OpenRouter — `GET https://openrouter.ai/api/v1/key`, DeepSeek — `GET https://api.deepseek.com/v1/models` (Bearer).
- Env-fallback ключей достаётся бесплатно: `SECONDBRAIN_OPENROUTER_KEY`, `SECONDBRAIN_DEEPSEEK_KEY`.
- Тесты в CloudProviderTests: регистрация обоих (chat-only, дефолт-модели, requiresKey), «чужой» keyID в ошибке missingAPIKey, запросы KeyVerifier (URL + заголовок Bearer).
