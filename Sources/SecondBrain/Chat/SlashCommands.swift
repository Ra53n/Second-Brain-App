// SlashCommands.swift — слэш-команды поля ввода чата (задача 22).
//
// Расширяемый реестр: новая команда = новый case + запись в catalog.
// Неизвестная команда («/опечатка») перехватывается ЛОКАЛЬНО с подсказкой —
// отправлять её модели бессмысленно и сбивает пользователя с толку.

import Foundation

/// Разобранная слэш-команда ввода.
enum SlashCommand: Equatable {
    /// «/help вопрос…» — ответ по документации выбранного проекта.
    case help(question: String)
    /// «/help» без вопроса — показать usage.
    case helpUsage
    /// «/review <PR URL | owner/repo#n | local>» — code review (задача 37).
    /// Аргумент — сырая строка: адрес PR разбирает PRReference (тестируемый
    /// отдельно), пустой аргумент — usage.
    case review(argument: String)
    /// «/что-то» — неизвестная команда (локальная подсказка).
    case unknown(String)

    /// Описание команды для подсказок UI и usage-текста.
    struct Spec {
        let name: String
        let summary: String
    }

    static let catalog: [Spec] = [
        Spec(name: "/help",
             summary: "ответ на вопрос о выбранном проекте по его документации и git (репозиторий — Настройки → Инструменты)"),
        Spec(name: "/review",
             summary: "code review: /review <ссылка на PR | owner/repo#N | local> — ревью PR с GitHub или незакоммиченных изменений проекта")
    ]

    /// Разбирает ввод. nil — обычный текст (не команда): команда должна
    /// начинаться с «/» и буквы («1/2» и «/ 5» — не команды).
    static func parse(_ input: String) -> SlashCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              let first = trimmed.dropFirst().first, first.isLetter else { return nil }
        // Имя — до первого пробельного символа; остальное — аргумент.
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        let argument = body.dropFirst(name.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch name.lowercased() {
        case "help":
            return argument.isEmpty ? .helpUsage : .help(question: argument)
        case "review":
            return .review(argument: argument)
        default:
            return .unknown("/\(name)")
        }
    }

    /// Usage команды /review — примеры всех трёх форм. Для чтения тестов
    /// агентом в чате должны быть включены инструменты проекта.
    static func reviewUsageText(problem: String? = nil) -> String {
        var lines: [String] = []
        if let problem { lines.append(problem) }
        lines.append("Использование: `/review <ссылка | owner/repo#N | local>`")
        lines.append("- `/review https://github.com/owner/repo/pull/42` — ревью PR по ссылке")
        lines.append("- `/review owner/repo#42` — короткая форма")
        lines.append("- `/review local` — ревью незакоммиченных изменений выбранного репозитория (Настройки → «Инструменты»)")
        lines.append("Подсказка: включите в чате «Инструменты проекта», чтобы агент мог читать тесты и файлы.")
        return lines.joined(separator: "\n")
    }

    /// Usage-текст (локальный ответ на «/help» без вопроса и на unknown).
    static func usageText(unknownCommand: String? = nil) -> String {
        var lines: [String] = []
        if let unknownCommand {
            lines.append("Неизвестная команда «\(unknownCommand)».")
        }
        lines.append("Доступные команды:")
        for spec in catalog {
            lines.append("- `\(spec.name)` — \(spec.summary)")
        }
        lines.append("Пример: `/help где хранятся чаты?`")
        return lines.joined(separator: "\n")
    }
}
