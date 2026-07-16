# 20 — Документация проекта

## Цель
Чёткая документация проекта, пригодная как источник знаний для команды `/help` (задача 22): актуальный README, схема данных всех хранилищ приложения, карта документации.

## Зависимости
Нет (описывает уже существующее ядро 01–18).

## Контекст
README и docs/ (VISION, ARCHITECTURE, CONVENTIONS) существуют, но нет описания схемы данных: что и в каком формате лежит в Application Support, какая схема у rag.sqlite, что приложение пишет в vault. /help будет класть README+docs в контекст модели — документация должна отвечать на вопросы «где хранятся чаты», «какая схема индекса», «что приложение никогда не трогает».

## Объём работ
- [ ] `docs/DATA-MODEL.md` — схема данных:
  - раскладка `~/Library/Application Support/SecondBrain/`: settings.json (поля AppSettings с дефолтами), chats.json (Chat → ChatMessage → ChatConfiguration), mcp-servers.json (синтаксис `keychain:<имя>`), routing.json, meetings.json, meeting_settings.json, `<vaultID>/rag.sqlite` (таблицы из RagIndex), WhisperKit/;
  - конвенции: tolerant-decoding, карантин `.corrupt.json`, «SQLite-индексы всегда пересоздаваемы»;
  - раскладка vault: заметки, записи, sidecar JSON; что приложение пишет и что никогда не трогает;
  - Keychain-аккаунты; внутренний API инструментов: ToolDefinition, схема qualified-имён MCP (`slug__tool`).
- [ ] Обновить `README.md`: статус, функции по модулям, сборка/тесты, карта документации, workflow tasks/ + ссылка на BACKLOG.md.
- [ ] `docs/ARCHITECTURE.md`: ссылка на DATA-MODEL.md из раздела про данные.

## Вне объёма
- Пользовательская справка (help внутри приложения), скриншоты, туториалы.
- Автогенерация документации из кода.
- Модуль Tools/ (появится в задаче 21 — она же и допишет его в ARCHITECTURE).

## Критерии приёмки
- Документация фактически точна: каждое утверждение о файлах/схемах сверено с кодом (SettingsStore, ChatStore, MCPServerStore, RagIndex, VaultManager).
- После задачи 22 `/help` отвечает на «где хранятся чаты?» и «какая схема rag.sqlite?» только по этим докам.
- Тестов нет (нет новой core-логики) — допустимое исключение из общего правила.
