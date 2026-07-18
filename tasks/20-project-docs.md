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

## Результат

Сделано (2026-07-16):
- **docs/DATA-MODEL.md** (новый) — полная схема данных: раскладка Application Support (settings.json / chats.json / mcp-servers.json / routing.json / meetings.json / meeting_settings.json / `<vault-id>`/search.sqlite и rag.sqlite / WhisperKit), общие конвенции персистентности (атомарная запись, decodeIfPresent, карантин `.corrupt.json`, пересоздаваемость индексов), детальные схемы AppSettings/Chat/ChatConfiguration/MCPServer/routing, SQL-схемы обеих SQLite-БД, раскладка vault (что пишем / что не трогаем), Keychain-сервис, остаточные UserDefaults-ключи, внутренний API инструментов (ToolDefinition, ToolUseLoop, qualified-имена `slug__tool`).
- **README.md** — переписан: секция «Возможности» по модулям, статус со ссылкой на BACKLOG.md, карта документации (+DATA-MODEL.md), команды сборки и тестов (включая DEVELOPER_DIR).
- **docs/ARCHITECTURE.md** — добавлена секция «Схема данных» со ссылкой на DATA-MODEL.md.

Все факты сверены с кодом (SettingsStore, ChatModels, MCPServer, FunctionRouting, RagIndex, SearchIndex, VaultTree/VaultID, RecordingMetadata, KeyStore). Отклонений от плана нет. Для агентов задачи 22: DATA-MODEL.md — главный источник для проверки /help.
