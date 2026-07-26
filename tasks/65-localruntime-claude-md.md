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

- [ ] `Sources/SecondBrain/LocalRuntime/CLAUDE.md` создан, все обязательные секции на месте.
- [ ] Явно описана разница жизненного цикла Ollama (child-процесс) и WhisperKit (in-process).
- [ ] `./scripts/build.sh` зелёный.
