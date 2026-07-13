// AutoBackup.swift — чистая логика авто-бэкапа vault (задача 16).
//
// Авто-бэкап: по таймеру (интервал настраивается, дефолт — выключен) если в
// vault есть изменения — commit «vault backup: <дата>» (формат сообщений — как
// пользователь делает сейчас руками) и push. Вся решающая логика вынесена
// сюда в чистые функции: тестируется мок-часами и синтетическими статусами,
// без git и таймеров. Исполняет план SyncViewModel.

import Foundation

enum AutoBackup {
    /// Сообщение авто-коммита: «vault backup: 2026-07-01 20:42:14» —
    /// воспроизводим формат существующей истории vault пользователя.
    /// timeZone инъектируется для детерминированных тестов.
    static func commitMessage(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "vault backup: " + formatter.string(from: date)
    }

    /// Пора ли запускать бэкап. interval ≤ 0 — авто-бэкап выключен.
    static func isDue(now: Date, lastAttempt: Date?, interval: TimeInterval) -> Bool {
        guard interval > 0 else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }

    /// План одного прогона бэкапа по текущему статусу.
    struct Plan: Equatable {
        var needsCommit: Bool
        var needsPush: Bool

        static let nothing = Plan(needsCommit: false, needsPush: false)
    }

    /// Решает, что делать: изменения → commit; после коммита или при уже
    /// накопленных ahead-коммитах (прошлый push не удался) → push. Повторные
    /// прогоны без новых изменений НЕ создают дублирующих коммитов — только
    /// допушивают. Конфликтное (unmerged) состояние не трогаем: его должен
    /// разрешить пользователь.
    static func plan(status: GitStatus, hasRemote: Bool) -> Plan {
        guard status.conflicted.isEmpty else { return .nothing }
        let needsCommit = !status.changes.isEmpty
        let needsPush = hasRemote && (needsCommit || status.ahead > 0)
        return Plan(needsCommit: needsCommit, needsPush: needsPush)
    }
}

/// Рекомендации по .gitignore vault: служебные файлы Obsidian/macOS и большие
/// аудиозаписи встреч (git от гигабайт аудио пухнет; LFS — вручную, вне объёма).
enum GitignoreAdvisor {
    /// Записи, которые стоит иметь в .gitignore любого vault.
    static let baseline = [".obsidian/workspace*", ".DS_Store"]
    /// Аудиозаписи встреч — отдельным пунктом: пользователь решает сам
    /// (игнорировать или возить в git/LFS).
    static let recordings = "Meetings/_recordings/"

    /// Каких рекомендованных записей ещё нет в содержимом .gitignore.
    static func missingEntries(in content: String, includeRecordings: Bool = true) -> [String] {
        let existing = Set(content.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) })
        var wanted = baseline
        if includeRecordings { wanted.append(recordings) }
        return wanted.filter { !existing.contains($0) }
    }

    /// Содержимое .gitignore после дописывания записей (с разделительным
    /// комментарием; исходный текст не переписывается — только дополняется).
    static func appending(_ entries: [String], to content: String) -> String {
        guard !entries.isEmpty else { return content }
        var result = content
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        result += "# Second Brain: служебное и большие файлы\n"
        result += entries.joined(separator: "\n") + "\n"
        return result
    }
}
