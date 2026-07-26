# Задача 65: `CLAUDE.md` для модуля `LocalRuntime/`

## Тип

документация

## Модель

haiku

## Цель

`Sources/SecondBrain/LocalRuntime/` управляет локальными подпроцессами (Ollama) и
in-process моделью (WhisperKit) — самое чувствительное к инварианту №2 место в проекте, но
без модульного `CLAUDE.md`. Инварианты жизненного цикла процессов сейчас разбросаны по
комментариям в коде.

## Зависимости

Нет.

## Объём

1. Создать `Sources/SecondBrain/LocalRuntime/CLAUDE.md` по шаблону существующих модульных
   CLAUDE.md (пример — `Sources/SecondBrain/RAG/CLAUDE.md`).
2. «Что здесь живёт»: `OllamaManager`, `OllamaProvider`, `OllamaModels`,
   `BackgroundProcessRegistry` (если он логически принадлежит этому модулю — уточнить по
   факту его использования только здесь или шире, и в этом случае просто сослаться, не
   дублировать описание), `WhisperKitProvider`, `WhisperModels`.
3. «Инварианты» — explicit связь с инвариантом №2 проекта: как `OllamaManager` регистрирует
   процесс, идле-таймаут, гарантия убийства в `applicationWillTerminate`, отличие
   in-process WhisperKit (нет отдельного процесса, но есть память/модель) от child-процесса
   Ollama.

## Вне объёма

Правка кода `LocalRuntime/`, изменение поведения `BackgroundProcessRegistry`.

## Критерии приёмки

- [x] `Sources/SecondBrain/LocalRuntime/CLAUDE.md` создан, все обязательные секции на месте.
- [x] Явно описана разница жизненного цикла Ollama (child-процесс) и WhisperKit (in-process).
- [x] `./scripts/build.sh` зелёный.

## Отчёт тестов

Проверено:
- Структура модуля: `OllamaManager`, `OllamaProvider`, `OllamaModels`, `BackgroundProcessRegistry`, `WhisperKitProvider`, `WhisperModels`, плюс UI-слой `LocalModelsPane`/`WhisperModelsSection` — тоже файлы этого модуля, перечислены в «Что здесь живёт».
- Инварианты жизненного цикла: регистрация spawned-процессов в реестре, idle-таймауты для Ollama и WhisperKit, гарантированное гашение в `applicationWillTerminate`.
- Разница: Ollama — child-процесс (регистрируется, гасится по SIGTERM→SIGKILL), WhisperKit — in-process модель (выгружается из памяти по idle).
- `BackgroundProcessRegistry` используется несколькими модулями, поэтому только ссылка, не дубль описания.
- Файл добавлен в `exclude` `Package.swift`.

Круг 2 (после NO-GO ревьюера):
- Idle-таймер: сверено с кодом построчно — `OllamaManager.swift:306` `Timer.scheduledTimer(withTimeInterval: 30, …)`,
  `WhisperKitProvider.swift:170` `withTimeInterval: 60`. Текст исправлен: интервалы названы раздельно
  (30 с у Ollama, 60 с у WhisperKit), обобщение «минутный таймер для обеих» убрано.
- `OllamaProvider` переописан как адаптер `ChatProvider`/`EmbeddingProvider` (делегирует `OllamaManager.ensureRunning`/`markUsed`
  и `OllamaClient`), не HTTP-клиент — сверено с `OllamaProvider.swift:9-67`.
- `OllamaModels` переописан: содержит DTO, чистые парсеры (`OllamaParsing`) И реальный HTTP-клиент `struct OllamaClient`
  (`OllamaModels.swift:185`, эндпойнты `/api/tags`, `/api/pull`, `/api/delete`, `/api/chat`, `/api/embed`) — раньше
  `OllamaClient` вообще не упоминался.
- «Куда не лезть»: убраны `LocalModelsPane`/`WhisperModelsSection` (по факту файлы этого же модуля — `ls
  Sources/SecondBrain/LocalRuntime/` подтверждает), добавлены в «Что здесь живёт». Раздел заменён на реально
  внешние границы: абстракции `ChatProvider`/`EmbeddingProvider`/`ProviderRegistry` (`LLM/`) и tool-расширение
  Ollama (`MCP/ProviderToolSupport.swift`, существование файла проверено).
- Остальные факты (имена методов `startIdleTimer`, `unloadIfIdle`, `shutdownIfIdle`, `setIdleTimeout`, `markUsed`,
  `spawnedProcess`, `.runningExternal`, `registry.register()`, `engineState`/`.transcribing`) перепроверены grep'ом
  по коду модуля — расхождений не найдено.

Build результат: зелёный (`./scripts/build.sh` → «Build complete!»).

## Результат

`Sources/SecondBrain/LocalRuntime/CLAUDE.md` создан по шаблону `RAG/CLAUDE.md`, добавлен в
`exclude` `Package.swift`. Два круга ревью: первый NO-GO — неверный idle-таймер (обобщён как
«60с для обоих», реально Ollama 30с/WhisperKit 60с), `OllamaProvider` неверно назван HTTP-
клиентом (это адаптер, реальный клиент — `OllamaClient`), `LocalModelsPane`/`WhisperModelsSection`
ошибочно в «Куда не лезть» вместо «Что здесь живёт». Все три исправлены и сверены построчно
с кодом. Второй круг — `GO`.

Код `LocalRuntime/` и поведение `BackgroundProcessRegistry` не менялись — задача только
документация.
