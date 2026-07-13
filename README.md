# Second Brain

macOS-приложение «второй мозг»: Obsidian-совместимый vault заметок + запись и транскрипция встреч + чат с LLM по своей базе знаний (RAG) + MCP-интеграции + git-синхронизация.

## Статус

Проект в разработке. План и прогресс: [tasks/00-INDEX.md](tasks/00-INDEX.md).

## Как ведётся разработка

Каждая задача выполняется отдельной сессией кодового агента (Claude Code):

```
Возьми задачу 01 из tasks/ и выполни её.
```

Агент сам прочитает [CLAUDE.md](CLAUDE.md), файл задачи, выполнит работу, прогонит тесты и отметит прогресс в индексе.

## Документация

- [docs/VISION.md](docs/VISION.md) — продукт: функции и сценарии.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — архитектура и технические решения.
- [docs/CONVENTIONS.md](docs/CONVENTIONS.md) — практики кода (унаследованы из Manager Assistant).

## Сборка (после задачи 01)

```bash
swift build        # debug
./run.sh           # release + SecondBrain.app
./install.sh       # установка в /Applications
./dist.sh          # дистрибутив: подпись + dist/*.dmg|*.zip (задача 18)
```

Установка на другом Mac — [INSTALL.md](INSTALL.md).
