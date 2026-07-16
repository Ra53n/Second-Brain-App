# Second Brain

macOS-приложение «второй мозг»: Obsidian-совместимый vault заметок + запись и транскрипция встреч + чат с LLM по своей базе знаний (RAG) + MCP-интеграции + git-синхронизация.

## Возможности

- **Заметки**: markdown-редактор с live preview, `[[wikilinks]]` и backlinks, полнотекстовый поиск (SQLite FTS5), quick switcher. Vault — обычная папка .md-файлов, открывается в Obsidian.
- **Встречи**: запись микрофона и системного звука (Core Audio process tap), пайплайн запись → транскрипция → summary → заметка в vault (FSM с ретраями, переживает перезапуск).
- **LLM**: облачные провайдеры (OpenAI, Gemini, Deepgram, AssemblyAI) и локальные (Ollama как управляемый процесс, WhisperKit для транскрипции) за единой абстракцией; роутинг «функция → модель» настраивается.
- **Чат**: диалоги с историей, per-чат выбор модели, RAG-ответы по vault с цитатами-ссылками на заметки, вызов MCP-инструментов (Jira/Confluence и любые stdio-серверы).
- **Синхронизация**: git-панель (commit/push/pull), авто-бэкап по таймеру, разрешение конфликтов; секреты — только Keychain.

## Статус

Ядро готово: задачи 01–18 выполнены. Идёт полировка и расширение: план и прогресс — [tasks/00-INDEX.md](tasks/00-INDEX.md), очередь будущих задач — [tasks/BACKLOG.md](tasks/BACKLOG.md).

## Как ведётся разработка

Проект разрабатывается атомарными задачами из `tasks/` — каждая выполняется отдельной сессией кодового агента (Claude Code):

```
Возьми задачу NN из tasks/ и выполни её.
```

Агент сам прочитает [CLAUDE.md](CLAUDE.md), файл задачи, выполнит работу, прогонит тесты и отметит прогресс в индексе. Новые идеи и отложенные задачи записываются в [tasks/BACKLOG.md](tasks/BACKLOG.md) и «вырастают» оттуда в нумерованные файлы задач.

## Документация

- [docs/VISION.md](docs/VISION.md) — продукт: функции и сценарии.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — архитектура, модули, ключевые потоки данных.
- [docs/DATA-MODEL.md](docs/DATA-MODEL.md) — схема данных: что и где хранится (settings/chats/индексы/vault).
- [docs/CONVENTIONS.md](docs/CONVENTIONS.md) — практики кода (унаследованы из Manager Assistant).

## Сборка и тесты

```bash
swift build        # debug
swift run          # запуск для разработки (без .app)
./run.sh           # release + SecondBrain.app
./install.sh       # установка в /Applications
./dist.sh          # дистрибутив: подпись + dist/*.dmg|*.zip

# Тесты требуют полный Xcode toolchain
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
```

Установка на другом Mac — [INSTALL.md](INSTALL.md).
