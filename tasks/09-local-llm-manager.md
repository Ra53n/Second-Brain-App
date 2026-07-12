# 09 — Менеджер локальных LLM

## Цель
Локальные модели работают через Ollama, которым приложение полностью управляет: детект/подсказка установки, скачивание моделей с прогрессом, ленивый запуск фоновым процессом, гашение при простое и гарантированное убийство при выходе из приложения.

## Зависимости
07.

## Контекст
Требование пользователя дословно: «запускать процесс в фоне и гасить его, если он больше не нужен; при закрытии приложения все фоновые процессы тоже гасились и убивались». Эталон — `RagOllamaLauncher.swift` в MA: он уже умеет spawn/`stopIfSpawned` и вызывается из `applicationWillTerminate` (см. App.swift MA). Портируй и обобщи. Заглушка `BackgroundProcessRegistry` создана задачей 01.

## Объём работ
- [ ] `LocalRuntime/BackgroundProcessRegistry.swift`: реальная реализация — регистрация всех запущенных `Process`, `terminateAll()` (SIGTERM → таймаут → SIGKILL), запуск дочерних в отдельной process group, чтобы убивать всё дерево; вызов из `applicationWillTerminate` уже подключён.
- [ ] `LocalRuntime/OllamaManager.swift` (порт+расширение RagOllamaLauncher):
  - детект: бинарь в PATH/`/usr/local/bin`/`/opt/homebrew/bin`, уже бегущий сервер (GET /api/version);
  - если не установлен — понятный UI-путь установки (открыть ollama.com / команда brew), не молчаливый фейл;
  - ленивый старт `ollama serve` при первом обращении, health-check с ретраями;
  - idle-shutdown: таймер с последнего запроса (настраиваемый, дефолт 10 мин) → останов, **только если процесс запускали мы** (чужой Ollama не трогаем);
  - `stopIfSpawned()` при выходе.
- [ ] `LocalRuntime/OllamaModels.swift`: список установленных моделей (/api/tags), скачивание (/api/pull, стрим прогресса), удаление; рекомендуемый стартовый набор (компактная чат-модель + эмбеддинг-модель, например qwen3 и nomic-embed-text — уточни актуальные на момент реализации).
- [ ] `LocalRuntime/OllamaProvider.swift`: `ChatProvider` (+стриминг, /api/chat) и `EmbeddingProvider` (/api/embed) поверх локального сервера; регистрация в ProviderRegistry с признаком «локальный».
- [ ] UI: раздел управления локальными моделями (статус рантайма: остановлен/запускается/работает; список моделей; скачивание с прогресс-баром; кнопка «Остановить сейчас»).

## Вне объёма
Локальная транскрипция (10 — WhisperKit, не Ollama), выбор моделей per-функция в настройках (17).

## Критерии приёмки
- Тесты: реестр процессов (мок-Process: terminateAll шлёт TERM, эскалирует KILL), idle-таймер (инжектируемые часы), DTO Ollama API по фикстурам, логика «не гасить чужой сервер».
- Ручная проверка: чат с локальной моделью работает; после 10 мин простоя `pgrep ollama` пуст; во время работы модели выйти из приложения — `pgrep ollama` пуст; при уже запущенном пользователем Ollama приложение подключается и при выходе его НЕ убивает.

## Подсказки
- Process group: `posix_spawn` с `POSIX_SPAWN_SETPGROUP` либо Process + `setpgid` через promoted API нет — практичный путь: запускать через `/bin/sh -c 'exec ollama serve'` и убивать `kill(-pid)`. Посмотри, как выкрутился MA.
- `applicationShouldTerminateAfterLastWindowClosed = true` (из 01) означает: выход по закрытию окна — тоже путь через `applicationWillTerminate`, проверь оба.
- Скачивание модели — долго; UI не должен блокироваться, прогресс из NDJSON-стрима /api/pull.

## Результат

Выполнено; `swift build` и `swift test` зелёные (422 теста, +20 новых).

**Что сделано** (порт+обобщение RagOllamaLauncher/LocalModelsClient из MA):

- `LocalRuntime/BackgroundProcessRegistry.swift` — реальная реализация: протокол `ManagedProcess` (моки в тестах), `terminateAll(gracePeriod:)` с эскалацией SIGTERM → 3 с ожидания → SIGKILL выжившим; сигнал группе через killpg, если ребёнок — лидер группы, иначе самому процессу.
- `LocalRuntime/OllamaManager.swift` — жизненный цикл: детект бинаря (PATH + Ollama.app + Homebrew + /usr/local), ленивый `ensureRunning()` (уже отвечает → external, не спавним дубль; защита от параллельных стартов через startupTask), health-check GET /api/version с ретраями, `IdleShutdownPolicy` (10 мин, инжектируемые часы) + таймер каждые 30 с, `stopNow()`/`shutdownIfIdle()` гасят ТОЛЬКО свой спавн. Не установлен → `OllamaError.notInstalled` с понятным текстом (ollama.com / brew). Все зависимости (spawn/health/detect/часы) инжектируются.
- `LocalRuntime/OllamaModels.swift` — DTO (`OllamaModel`, `OllamaPullProgress`), чистые парсеры `OllamaParsing` (tags/pull-NDJSON/chat/chat-stream/embed), HTTP-клиент `OllamaClient` (tags, pull со стримом прогресса и отменой, delete, chat, chatStream NDJSON, embed). Рекомендуемый набор: qwen3:8b (чат) + nomic-embed-text (эмбеддинги RAG).
- `LocalRuntime/OllamaProvider.swift` — ChatProvider (+stream) и EmbeddingProvider (dimension 768, модель эмбеддингов nomic-embed-text фиксирована отдельно от чата); каждый вызов: ensureRunning → запрос → markUsed. `LocalProviders.register`: id "ollama", isLocal (ключ не нужен), доступен если бинарь установлен либо сервер уже отвечает.
- UI `LocalRuntime/LocalModelsPane.swift` — статус рантайма (остановлен/запускается/наш/внешний) + запуск/«Остановить сейчас», установка (ollama.com + brew-команда), список моделей с удалением, рекомендуемый набор и произвольный pull с прогресс-баром из NDJSON (не блокирует UI, отменяем).

**Отклонения**:
- UI живёт в разделе «Настройки» (задача 17 добавит остальные настройки вокруг) — отдельного раздела в сайдбаре по VISION нет.
- Process group при spawn НЕ устанавливается: Foundation.Process не даёт POSIX_SPAWN_SETPGROUP, трюк из подсказки (`sh -c 'exec …'`) группу тоже не создаёт. Реализовано: оппортунистический killpg + эскалация TERM→KILL; Ollama на SIGTERM сам корректно гасит runner-детей. ARCHITECTURE.md обновлён под реальность.

**Тесты**: BackgroundProcessRegistryTests (TERM всем живым, эскалация KILL «зависшему», идемпотентность, мёртвые не сигналятся; старые смоук-тесты переехали из ConfigTests), IdleShutdownPolicyTests (граница таймаута, сдвиг окна markUsed), OllamaManagerTests (external-сервер не гасится никогда, ленивый спавн с регистрацией в реестре, notInstalled, idle гасит только свой, hostPort), OllamaParsingTests (фикстуры ollama_tags/chat/embed + pull-стадии/ошибки/мусор).

**Ручная проверка не выполнялась** (нужен установленный Ollama): чат с локальной моделью; `pgrep ollama` пуст после 10 мин простоя и после выхода из приложения; при уже запущенном пользователем Ollama приложение подключается и при выходе НЕ убивает его.

**Агентам следующих задач**: 10 — секцию Whisper-моделей добавить в LocalModelsPane; 12/13 — Ollama уже в реестре провайдеров, роутер выбирает его для .chat/.embedding при недоступном облаке; 17 — настройка idle-таймаута.
