# secure-loop — правила модуля

Execution loop домашки Дня 14 (задача 104): автономный харнес, который гонит задачу
кодогенерации через LLM Gateway (задача 103) с security-шагом перед коммитом.

## Схема цикла

```
задача → [gateway] генерация Swift-кода → swift build
   ├─ упало → фидбек компилятора, новый круг (общий лимит 4)
   └─ ок → [gateway] security review (JSON-вердикт по severity)
        ├─ Critical/High → фидбек «исправь: …», новый круг
        ├─ только Medium/Low → WARNING в лог → git commit
        └─ чисто → git commit (одноразовый репо в out/work)
```

Оба вызова LLM — только через `POST $GW_URL/chat`; напрямую в DeepSeek харнес не
ходит. В контекст промпта харнес подкладывает фейковый AWS-ключ и email (генерятся
на рантайме) — input guard gateway обязан их маскировать (`inputAction=mask` в логе).

## Как запускать

- `GW_URL=https://<VPS_HOST>/gw ./secure-loop/run.sh [id]` — id: `t1-token`,
  `t2-logging`, `t3-api`; без id — все три подряд.
- Адрес VPS — в памяти `llm-gateway-vps`; в репозиторий, промпты и коммиты адрес
  не писать (BACKLOG п.67).
- Python системный 3.9, только stdlib — ничего не устанавливать.

## Как читать результат

- Консоль: круги, NO-GO security step с находками, WARNING, итог задачи
  (`committed` / `stopped-limit` / `gateway-blocked` / `verdict-unparsed`).
- `out/run-log.jsonl` — полный журнал: превью промптов (плантованные значения
  маскированы), `meta` gateway (inputAction, usage, costUsd), вердикты, сборки.
- `git -C secure-loop/out/work log --oneline` — что реально дошло до коммита;
  сам код — `out/work/Sources/Sandbox/Task*.swift`.
- Перехваты на стороне gateway — админка `/gw/admin` на VPS (токен в
  `/etc/llm-gateway.env`; в чат и файлы не печатать).

## Правила

- `Sources/` и `Tests/` приложения не трогать; все артефакты прогона — в
  `secure-loop/out/` (ignored). Каждый прогон пересоздаёт `out/work`.
- Известная дыра стенда (t3): `http://`-endpoint константой в `AppConfig.swift`
  проходит мимо security step (тот видит один файл) и мимо gateway (это не
  секрет). Это демонстрация «мимо обоих» — молча не чинить.
- Обрыв ответа по maxTokens детектится по незакрытому фенсу — харнес сам просит
  компактную версию; это не ошибка прогона.
