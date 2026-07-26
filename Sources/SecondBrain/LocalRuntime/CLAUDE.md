# Модуль LocalRuntime — правила

Локальные подпроцессы (Ollama) и in-process модели (WhisperKit). Самое чувствительное к
инварианту №2 место в проекте: жизненный цикл процессов от спавна до гарантированного
гашения на выходе.

## Что здесь живёт

- `BackgroundProcessRegistry` — единый владелец всех фоновых процессов приложения; регистрирует,
  отслеживает и гасит их по инварианту №2 (см. ниже). Используется также из `Tools/`,
  `MCP/`, не дублируется здесь описание.
- `OllamaManager` — жизненный цикл локального Ollama: ленивый спавн, health-check, idle-гашение
  по `IdleShutdownPolicy`, регистрация в реестре. Отличает свой процесс от чужого (external)
  и не трогает чужой при любых обстоятельствах.
- `OllamaProvider` — адаптер `ChatProvider`/`EmbeddingProvider` поверх `OllamaManager` +
  `OllamaClient`: перед каждым вызовом `ensureRunning()`, после — `markUsed()`; сам HTTP
  не делает.
- `OllamaModels` — DTO моделей Ollama, чистые парсеры API-ответов (`OllamaParsing`) и
  реальный HTTP-клиент `OllamaClient` (`/api/tags`, `/api/pull`, `/api/delete`, `/api/chat`,
  `/api/embed`, NDJSON-стриминг).
- `IdleShutdownPolicy` — чистая логика idle-таймаута (инжектируемые часы, тестируемость).
- `WhisperKitProvider` — провайдер локальной транскрипции: ленивая загрузка CoreML-модели
  в память, idle-выгрузка, управление вариантами (tiny → large-v3_turbo), прогресс транскрипции.
- `WhisperModels` / `WhisperModelStorage` — каталог вариантов, хранение моделей на диске
  (`~/Library/Application Support/SecondBrain/WhisperKit`), сканирование установленного.
- `LocalModelsPane` — UI управления моделями Ollama (список, загрузка, удаление).
- `WhisperModelsSection` — UI выбора и загрузки варианта WhisperKit.

## Инварианты

1. **Жизненный цикл Ollama (child-процесс) — инвариант №2 проекта:**
   - Спавн регистрируется в `BackgroundProcessRegistry.shared` немедленно.
   - Процесс гасится в `applicationWillTerminate` с эскалацией: SIGTERM (killpg) → 3 с → SIGKILL.
   - Гашение также срабатывает по idle-таймауту через `OllamaManager.shutdownIfIdle()`,
     вызываемому таймером каждые 30 с (задача 17).
   - Чужой процесс (внешний Ollama.app или ручной запуск) не гасится никогда: гасим ТОЛЬКО
     свой `spawnedProcess`.

2. **WhisperKit — in-process модель, без отдельного процесса ОС:**
   - Модель (гигабайты RAM) выгружается по idle-таймауту через `WhisperKitProvider.unloadIfIdle()`.
   - Выгрузка — стирание ссылки на `engine` (модель — данные `@MainActor`, не требуется
     синхронизация с реестром процессов).
   - Никоим образом не влияет на `BackgroundProcessRegistry`.

3. **Ленивый старт обоих рантаймов:** Ollama и WhisperKit загружаются при первом запросе,
   не при инициализации `AppModel`. Модуль `LLM/` выбирает провайдера через маршруты
   (`FunctionRouter`).

4. **Ollama сам не трогает внешний процесс:** если сервер уже отвечает на health-check,
   `OllamaManager.ensureRunning()` просто подключается; статус переходит в `.runningExternal`,
   `spawnedProcess` остаётся `nil`. При выходе приложения — нет попытки гашения.

5. **Idle-таймер разный по интервалу опроса, общий по логике:** `OllamaManager` проверяет
   `shouldShutdown` каждые 30 с, `WhisperKitProvider` — каждые 60 с; если прошло ≥ timeout
   с последнего использования — выключение. Timeout настраивается пользователем
   (задача 17) через `setIdleTimeout()`.

6. **Health-check Ollama без блокировки UI:** асинхронное обращение, тесты подменяют клиента
   (инжектируемая функция `health`).

## Как тестируем

- `OllamaManager` — цикл спавна и shutdown, различие своего/чужого процесса, idle-логика;
  все зависимости инжектируются (spawn, health, modelsLoader, binaryLocator). Реальный
  процесс в тестах не спавнится.
- `IdleShutdownPolicy` — `shouldShutdown` с мок-датами, переход из active → idle.
- `WhisperKitProvider` — ленивая загрузка движка, переключение вариантов, idle-выгрузка;
  `WhisperEngine` мокируется.
- `OllamaModels` — парсинг /api/tags, /api/pull, /api/chat на фикстурах без сервера.
- `WhisperModels` — сканирование папок установленных вариантов на temp-директориях.

## Частые ошибки прошлых задач

- **Спавн не регистрируется в реестре.** Процесс остаётся зависшим при выходе приложения
  (инвариант №2 нарушен). Обязателен `registry.register()` сразу после успешного spawn.
- **Гашение чужого процесса.** Если `spawnedProcess == nil` (внешний Ollama), `stopNow()`
  просто меняет статус; не ищет процесс по PID или портам.
- **WhisperKit выгружается посреди транскрипции.** Защита: `if case .transcribing = engineState { return }`.
- **Idle-таймер не запускается при инициализации.** Обязателен вызов `startIdleTimer()` в init.
- **Новое использование не сдвигает окно idle.** Обязателен `markUsed()` в `ensureRunning()`,
  `transcribe()` и других точках обращения к API.

## Куда не лезть

- Маршрутизацию выбора провайдера (Ollama vs облачные) — модуль `LLM/`.
- Абстракции `ChatProvider`/`EmbeddingProvider`/`ProviderRegistry` — модуль `LLM/`,
  здесь только их реализации поверх Ollama и WhisperKit.
- Регистрацию tool-расширения Ollama (function calling) — `MCP/ProviderToolSupport.swift`.
