# 01 — Каркас проекта

## Цель
Создать собираемый SPM-проект SecondBrain: пустое SwiftUI-окно с NavigationSplitView, скрипты сборки .app, первый тест — всё по образцу Manager Assistant.

## Зависимости
Нет (первая задача).

## Контекст
Репозиторий содержит только документацию (CLAUDE.md, docs/, tasks/). Эталон: `/Users/kostyanikitin/Desktop/Manager assistant` — SPM-only executable. Перед началом прочитай там `Package.swift`, `Sources/ManagerAssistant/App.swift`, `run.sh`, `install.sh`.

## Объём работ
- [ ] `Package.swift`: executableTarget `SecondBrain` (path `Sources/SecondBrain`) + testTarget `SecondBrainTests`; platforms `.macOS(.v14)`; пока без внешних зависимостей (swift-markdown-ui добавит задача 03).
- [ ] `Sources/SecondBrain/App/App.swift` — порт App.swift из MA: `@main` App + AppDelegate (activation policy, иконка, `applicationShouldTerminateAfterLastWindowClosed = true`). В `applicationWillTerminate` — вызов заглушки `BackgroundProcessRegistry.shared.terminateAll()` (пустая реализация в `LocalRuntime/BackgroundProcessRegistry.swift` с TODO на задачу 09 — хук должен существовать с первого дня).
- [ ] `Sources/SecondBrain/App/ContentView.swift` — NavigationSplitView: sidebar с заглушками разделов (Заметки / Встречи / Чат / Настройки), detail с плейсхолдером.
- [ ] Структура папок модулей из ARCHITECTURE.md (пустые папки не коммитятся — добавляй по файлу-заглушке только туда, где он уже осмыслен: App/, LocalRuntime/).
- [ ] Иконка: порт `icon/render_icon.swift` из MA с другой палитрой/символом (мозг 🧠) → `Sources/SecondBrain/Resources/AppIcon.icns`, подключить как resource.
- [ ] `run.sh` — порт из MA: `swift build -c release` → сборка `SecondBrain.app` (Info.plist: bundle id `com.local.second-brain`, `NSMicrophoneUsageDescription` — понадобится задаче 06).
- [ ] `install.sh` — порт из MA (установка в /Applications).
- [ ] Первый тест-смоук в `Tests/SecondBrainTests/` (например, дефолты будущего Config), чтобы `swift test` работал.

## Вне объёма
Любая функциональность: vault, редактор, LLM. Только каркас.

## Критерии приёмки
- `swift build` и `swift test` зелёные (DEVELOPER_DIR на Xcode).
- `swift run` открывает окно с sidebar.
- `./run.sh` создаёт запускаемый `SecondBrain.app` с иконкой.
- Комментарии по CONVENTIONS.md (файловые заголовки, `///`).

## Подсказки
- MA ставит иконку в рантайме через AppDelegate для `swift run` — перенеси этот трюк.
- `windowResizability(.contentMinSize)` как в MA.
- Info.plist генерируется heredoc-ом внутри run.sh — не заводи отдельный файл.

## Результат

Выполнено полностью, `swift build` / `swift test` (5 тестов) зелёные, `swift run` открывает окно с sidebar, `./run.sh` собирает `SecondBrain.app` с иконкой.

Что сделано:
- `Package.swift`: executableTarget `SecondBrain` + testTarget, macOS 14, без внешних зависимостей.
- `App/App.swift` — порт App.swift из MA (activation policy, рантайм-иконка для `swift run`, `applicationShouldTerminateAfterLastWindowClosed`). `applicationWillTerminate` зовёт `BackgroundProcessRegistry.shared.terminateAll()`.
- `LocalRuntime/BackgroundProcessRegistry.swift` — не совсем пустая заглушка: уже умеет `register(Process)` / `runningCount` / идемпотентный `terminateAll()` под NSLock (TODO на задачу 09 — лаунчер Ollama, idle-таймаут, process group).
- `App/ContentView.swift` — NavigationSplitView, sidebar с 4 разделами (enum `AppSection`), detail — `ContentUnavailableView`-плейсхолдеры.
- `App/Config.swift` — `appName`, `bundleID`, `appSupportDirectory`; тест фиксирует совпадение bundleID с run.sh.
- Иконка: `icon/render_icon.swift` + `icon/make_icon.sh` (порт из MA), бирюзово-зелёный squircle со стилизованным мозгом (NSBezierPath, без emoji). `AppIcon.icns` закоммичен.
- `run.sh` / `install.sh` — порт из MA (bundle id `com.local.second-brain`, `NSMicrophoneUsageDescription` для задачи 06).
- Тесты: `ConfigTests` + `BackgroundProcessRegistryTests`.

Отклонения от плана и что важно знать следующим задачам:
- **run.sh копирует SPM-ресурсный бандл** `SecondBrain_SecondBrain.bundle` в `Contents/Resources/` — в MA этого нет, но без него `Bundle.module` внутри .app падает fatalError при обращении к ресурсам. Новые `.copy`-ресурсы в Package.swift будут подхватываться автоматически.
- `.gitignore` уже существовал в репо; дополнен рабочими файлами иконки.
- Структура папок модулей из ARCHITECTURE.md специально НЕ создана заранее (пустые папки не коммитятся) — есть только `App/`, `LocalRuntime/`, `Resources/`. Каждая следующая задача создаёт свою папку сама.
