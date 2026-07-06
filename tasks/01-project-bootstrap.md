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
