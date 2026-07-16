// GitClient.swift — обёртка над git CLI для синхронизации vault (задача 16).
//
// Git вызывается как внешний процесс (без libgit2): меньше зависимостей, а
// auth бесплатно наследуется от системного git — osxkeychain credential
// helper для https и SSH-агент для ssh-remote. Приложение НИКОГДА не хранит
// и не видит пароли/токены; интерактивные запросы выключены
// (GIT_TERMINAL_PROMPT=0, ssh BatchMode) — вместо зависания вернётся ошибка.
//
// Все операции async с таймаутом; параллельные вызовы сериализуются
// внутренней очередью (два git в одном репо портят index.lock). Парсеры
// вынесены в чистые enum (GitStatusParser, GitLogParser, GitRemoteURL) —
// тестируются без запуска git.

import Foundation

// MARK: - Ошибки

/// Ошибки git-операций; сообщения пригодны для показа в UI.
enum GitError: LocalizedError, Equatable {
    /// git не найден или неработоспособен (обычно нет Command Line Tools).
    case gitUnavailable(String)
    /// Папка vault не является корнем git-репозитория.
    case notARepository
    /// Команда завершилась с ненулевым кодом; message — stderr.
    case commandFailed(command: String, message: String)
    /// Команда не уложилась в таймаут и была убита.
    case timeout(command: String)
    /// Автоматический merge не удался. Merge уже прерван (git merge --abort) —
    /// vault остался ровно в состоянии до pull, ничего не потеряно.
    case mergeConflict(files: [String])

    var errorDescription: String? {
        switch self {
        case .gitUnavailable(let detail):
            return "git недоступен: \(detail). Установите Command Line Tools: xcode-select --install"
        case .notARepository:
            return "Папка vault не является git-репозиторием."
        case .commandFailed(let command, let message):
            return "git \(command): \(message)"
        case .timeout(let command):
            return "git \(command) не ответил за отведённое время и был остановлен."
        case .mergeConflict(let files):
            return "Автоматическое слияние не удалось (конфликты: \(files.count)). Merge прерван, ваши файлы не тронуты."
        }
    }
}

// MARK: - Модели

/// Изменённый файл из `git status`.
struct GitFileChange: Identifiable, Equatable {
    enum Kind: String {
        case modified = "изменён"
        case added = "добавлен"
        case deleted = "удалён"
        case renamed = "переименован"
        case untracked = "новый"
    }

    let path: String
    let kind: Kind
    var id: String { path }
}

/// Снимок состояния репозитория (porcelain v2 + счётчики ahead/behind).
struct GitStatus: Equatable {
    /// Текущая ветка; "(detached)" при detached HEAD; nil — не распарсили.
    var branch: String?
    /// Upstream-ветка ("origin/main"); nil — не настроен.
    var upstream: String?
    /// Локальных коммитов, которых нет в upstream (актуально после fetch).
    var ahead = 0
    /// Коммитов в upstream, которых нет локально (актуально после fetch).
    var behind = 0
    /// Изменённые/новые/удалённые файлы (staged + unstaged + untracked).
    var changes: [GitFileChange] = []
    /// Файлы в конфликтном (unmerged) состоянии.
    var conflicted: [String] = []

    var isClean: Bool { changes.isEmpty && conflicted.isEmpty }
}

/// Коммит из `git log`.
struct GitCommit: Identifiable, Equatable {
    let hash: String
    let author: String
    let date: Date
    let subject: String
    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
}

/// Remote из `git remote -v`.
struct GitRemote: Equatable {
    let name: String
    let url: String
}

/// Сторона, чью версию принять при конфликте pull (`-X ours` / `-X theirs`).
enum GitMergeSide {
    case ours    // «принять свои»
    case theirs  // «принять удалённые»

    var strategyOption: String {
        switch self {
        case .ours: return "ours"
        case .theirs: return "theirs"
        }
    }
}

// MARK: - Парсер status --porcelain=v2

/// Чистый парсер вывода `git status --porcelain=v2 --branch`.
/// Формат стабилен и задокументирован в git-status(1).
enum GitStatusParser {
    static func parse(_ text: String) -> GitStatus {
        var status = GitStatus()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                status.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // «# branch.ab +1 -2» → ahead 1, behind 2.
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") {
                // «1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>» — 8 полей + путь
                // (путь может содержать пробелы, поэтому maxSplits).
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                status.changes.append(GitFileChange(path: String(parts[8]),
                                                    kind: kind(fromXY: parts[1])))
            } else if line.hasPrefix("2 ") {
                // Rename/copy: как «1», но с полем <X><score> и парой путей
                // «новый<TAB>старый» — показываем новый.
                let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10 else { continue }
                let newPath = parts[9].split(separator: "\t", maxSplits: 1)[0]
                status.changes.append(GitFileChange(path: String(newPath), kind: .renamed))
            } else if line.hasPrefix("u ") {
                // Unmerged: «u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>».
                let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                status.conflicted.append(String(parts[10]))
            } else if line.hasPrefix("? ") {
                status.changes.append(GitFileChange(path: String(line.dropFirst(2)),
                                                    kind: .untracked))
            }
            // «! <path>» (ignored) не интересен.
        }
        return status
    }

    /// Тип изменения из двухбуквенного поля XY ("." — нет изменения на стороне).
    private static func kind(fromXY xy: Substring) -> GitFileChange.Kind {
        if xy.contains("A") { return .added }
        if xy.contains("D") { return .deleted }
        if xy.contains("R") { return .renamed }
        return .modified
    }
}

// MARK: - Парсер веток

/// Ветки репозитория из `git for-each-ref` (задача 21).
struct GitBranches: Equatable {
    /// Текущая ветка; nil при detached HEAD или пустом репозитории.
    var current: String?
    var local: [String] = []
    /// Remote-ветки в коротком виде («origin/main»), без origin/HEAD.
    var remote: [String] = []
}

/// Чистый парсер `git for-each-ref --format=<format> refs/heads refs/remotes`.
/// Формат: маркер HEAD + короткое имя + полный refname (по нему надёжно
/// различаются локальные и remote-ветки — короткое имя может содержать «/»
/// и у локальной ветки вида «feature/x»).
enum GitBranchParser {
    static let format = "%(HEAD)%09%(refname:short)%09%(refname)"

    static func parse(_ text: String) -> GitBranches {
        var branches = GitBranches()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let isHead = fields[0] == "*"
            let short = String(fields[1])
            let full = fields[2]
            if full.hasPrefix("refs/heads/") {
                branches.local.append(short)
                if isHead { branches.current = short }
            } else if full.hasPrefix("refs/remotes/") {
                // origin/HEAD — символическая ссылка на дефолтную ветку, не ветка.
                guard !full.hasSuffix("/HEAD") else { continue }
                branches.remote.append(short)
            }
        }
        return branches
    }
}

// MARK: - Парсер log

/// Парсер `git log --pretty=format:%H<US>%an<US>%aI<US>%s<RS>`.
/// Разделители — управляющие символы US/RS: не встречаются в темах коммитов.
enum GitLogParser {
    static let format = "%H%x1f%an%x1f%aI%x1f%s%x1e"

    static func parse(_ text: String) -> [GitCommit] {
        let iso = ISO8601DateFormatter()
        return text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .newlines) }
            guard fields.count == 4, let date = iso.date(from: fields[2]) else { return nil }
            return GitCommit(hash: fields[0], author: fields[1], date: date, subject: fields[3])
        }
    }
}

// MARK: - URL remote: встроенные учётные данные

/// Детект анти-паттерна «токен в URL remote» (https://TOKEN@github.com/…).
/// Приложение предлагает переписать URL без секрета — auth должен идти через
/// osxkeychain helper или SSH (CONVENTIONS.md «Секреты»).
enum GitRemoteURL {
    /// Учётные данные из userinfo-части http(s)-URL («токен» или «user:токен»);
    /// nil — их нет. Для ssh-URL всегда nil: там userinfo («git@») — логин
    /// подключения, а не секрет.
    static func embeddedCredential(in url: String) -> String? {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard let schemeRange = url.range(of: "://") else { return nil }
        let rest = url[schemeRange.upperBound...]
        // userinfo — всё до «@», если «@» стоит раньше первого «/» (иначе это
        // не userinfo, а часть пути).
        guard let at = rest.firstIndex(of: "@") else { return nil }
        if let slash = rest.firstIndex(of: "/"), slash < at { return nil }
        let userinfo = String(rest[..<at])
        return userinfo.isEmpty ? nil : userinfo
    }

    /// Тот же URL без userinfo-части (для `git remote set-url`).
    static func strippingCredential(_ url: String) -> String {
        guard embeddedCredential(in: url) != nil,
              let schemeRange = url.range(of: "://") else { return url }
        let rest = url[schemeRange.upperBound...]
        guard let at = rest.firstIndex(of: "@") else { return url }
        return String(url[..<schemeRange.upperBound]) + String(rest[rest.index(after: at)...])
    }
}

// MARK: - Клиент

/// Обёртка над git CLI, привязанная к одному репозиторию (корню vault).
/// Actor + внутренняя FIFO-очередь: операции строго последовательны.
actor GitClient {
    let repoURL: URL
    /// Путь к бинарю git; nil — не найден (все операции бросят gitUnavailable).
    private let gitPath: String?

    init(repoURL: URL) {
        self.repoURL = repoURL
        self.gitPath = Self.detectGitPath()
    }

    /// Ищем git по стандартным путям. /usr/bin/git есть всегда (шим Xcode),
    /// но без Command Line Tools он нерабочий — это проверит ensureAvailable().
    nonisolated static func detectGitPath() -> String? {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    // MARK: Последовательная очередь операций

    // Параллельные git-процессы в одном репозитории дерутся за index.lock;
    // методы актора могут перемежаться на await — поэтому явный FIFO-замок.
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: Операции

    /// Проверяет, что git запускается (`--version`). Бросает gitUnavailable
    /// с текстом ошибки (обычно — предложение установить Command Line Tools).
    func ensureAvailable() async throws {
        do {
            _ = try await run(["--version"], timeout: 20)
        } catch let error as GitError {
            if case .commandFailed(_, let message) = error {
                throw GitError.gitUnavailable(message)
            }
            throw error
        }
    }

    /// Является ли папка vault КОРНЕМ git-репозитория. Вложенность vault в
    /// чужой родительский репозиторий считаем «нет»: коммитить родительский
    /// репозиторий целиком от имени vault — опасно.
    func isRepository() async -> Bool {
        guard let out = try? await run(["rev-parse", "--show-toplevel"]) else { return false }
        let top = URL(fileURLWithPath: out.trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath().standardizedFileURL.path
        let repo = repoURL.resolvingSymlinksInPath().standardizedFileURL.path
        return top == repo
    }

    /// `git init` в корне vault.
    func initRepository() async throws {
        _ = try await run(["init"])
    }

    /// Текущее состояние: ветка, upstream, ahead/behind, изменения, конфликты.
    func status() async throws -> GitStatus {
        GitStatusParser.parse(try await run(["status", "--porcelain=v2", "--branch"]))
    }

    /// `git add -A` + `git commit -m`. Возвращает false, если коммитить нечего
    /// (изменений нет) — коммит не создаётся, дубликаты исключены.
    func commitAll(message: String) async throws -> Bool {
        _ = try await run(["add", "-A"])
        let pending = try await run(["status", "--porcelain"])
        guard !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        _ = try await run(["commit", "-m", message])
        return true
    }

    /// `git push`; если у ветки нет upstream — повторяет с `-u origin HEAD`.
    func push() async throws {
        do {
            _ = try await run(["push"], timeout: 180)
        } catch let error as GitError {
            guard case .commandFailed(_, let message) = error,
                  message.contains("no upstream branch") else { throw error }
            _ = try await run(["push", "-u", "origin", "HEAD"], timeout: 180)
        }
    }

    /// `git pull --no-rebase` (обычный merge). Конфликт: merge прерывается
    /// (`merge --abort`), бросается mergeConflict со списком файлов — vault
    /// никогда не остаётся в полу-смердженном состоянии. `resolving` повторяет
    /// pull с `-X ours/theirs` (конфликтные куски решаются в пользу стороны).
    func pull(resolving side: GitMergeSide? = nil) async throws {
        var args = ["pull", "--no-rebase"]
        if let side { args += ["-X", side.strategyOption] }
        do {
            _ = try await run(args, timeout: 300)
        } catch let error as GitError {
            guard case .commandFailed = error else { throw error }
            // Merge в процессе? Собираем конфликтные файлы и прерываем merge.
            let merging = (try? await run(["rev-parse", "-q", "--verify", "MERGE_HEAD"])) != nil
            guard merging else { throw error }
            let files = (try? await status().conflicted) ?? []
            _ = try? await run(["merge", "--abort"])
            throw GitError.mergeConflict(files: files)
        }
    }

    /// `git fetch` — обновить remote-tracking ветки (для точных ahead/behind).
    func fetch() async throws {
        _ = try await run(["fetch", "--quiet"], timeout: 120)
    }

    /// Последние коммиты. Пустой репозиторий (нет коммитов) → [].
    func log(limit: Int = 20) async throws -> [GitCommit] {
        guard let out = try? await run(["log", "-n", "\(limit)",
                                        "--pretty=format:\(GitLogParser.format)"]) else { return [] }
        return GitLogParser.parse(out)
    }

    /// Локальные и remote-ветки; текущая помечена (задача 21).
    func branches() async throws -> GitBranches {
        GitBranchParser.parse(try await run(["for-each-ref",
                                             "--format=\(GitBranchParser.format)",
                                             "refs/heads", "refs/remotes"]))
    }

    /// Отслеживаемые git файлы (`ls-files`), пути относительно корня (задача 21).
    func trackedFiles() async throws -> [String] {
        try await run(["ls-files"])
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Remotes из `git remote -v` (по одному на имя, URL — fetch-вариант).
    func remotes() async throws -> [GitRemote] {
        let out = try await run(["remote", "-v"])
        var seen = Set<String>()
        var result: [GitRemote] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, !seen.contains(String(parts[0])) else { continue }
            seen.insert(String(parts[0]))
            let url = parts[1].replacingOccurrences(of: " (fetch)", with: "")
                .replacingOccurrences(of: " (push)", with: "")
            result.append(GitRemote(name: String(parts[0]), url: url))
        }
        return result
    }

    func addRemote(name: String, url: String) async throws {
        _ = try await run(["remote", "add", name, url])
    }

    func setRemoteURL(name: String, url: String) async throws {
        _ = try await run(["remote", "set-url", name, url])
    }

    /// `git config <key> <value>` в репозитории (нужно тестам: identity).
    func configSet(_ key: String, _ value: String) async throws {
        _ = try await run(["config", key, value])
    }

    /// Есть ли сохранённые учётные данные для https-хоста (osxkeychain и др.
    /// настроенные helpers). Вывод с секретами НЕ сохраняется и не логируется —
    /// проверяется только наличие строки password=.
    func hasStoredCredentials(host: String) async -> Bool {
        guard let out = try? await run(["credential", "fill"],
                                       stdin: "protocol=https\nhost=\(host)\n\n",
                                       timeout: 20) else { return false }
        return out.contains("password=")
    }

    /// Произвольная git-команда (для тестов и редких сценариев).
    @discardableResult
    func raw(_ args: [String], timeout: TimeInterval = 60) async throws -> String {
        try await run(args, timeout: timeout)
    }

    // MARK: Запуск процесса

    /// Запускает git с аргументами в корне репозитория через FIFO-очередь.
    /// Возвращает stdout; ненулевой код выхода → commandFailed(stderr).
    private func run(_ args: [String],
                     stdin: String? = nil,
                     timeout: TimeInterval = 60) async throws -> String {
        guard let gitPath else {
            throw GitError.gitUnavailable("бинарь git не найден")
        }
        await lock()
        defer { unlock() }
        // core.quotepath=false: иначе кириллические пути в выводе git
        // C-экранируются («"\320\276..."») и парсеры получают кашу.
        let fullArgs = ["-c", "core.quotepath=false"] + args
        let result = try await Self.execute(gitPath: gitPath, arguments: fullArgs,
                                            directory: repoURL, stdin: stdin, timeout: timeout)
        let command = args.first ?? ""
        if result.timedOut {
            throw GitError.timeout(command: command)
        }
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(command: command,
                                         message: message.isEmpty ? "код \(result.exitCode)" : message)
        }
        return result.stdout
    }

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    /// Синхронный запуск на GCD-потоке (block там допустим), мост в async.
    /// Окружение наследуется (HOME, SSH_AUTH_SOCK — иначе сломается auth),
    /// интерактивные запросы выключены: GUI-приложению негде их показать.
    private nonisolated static func execute(gitPath: String,
                                            arguments: [String],
                                            directory: URL,
                                            stdin: String?,
                                            timeout: TimeInterval) async throws -> RunResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try executeSync(
                        gitPath: gitPath, arguments: arguments, directory: directory,
                        stdin: stdin, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func executeSync(gitPath: String,
                                                arguments: [String],
                                                directory: URL,
                                                stdin: String?,
                                                timeout: TimeInterval) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory

        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"                 // не ждать ввода пароля
        if env["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes" // ssh тоже без вопросов
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        do {
            try process.run()
        } catch {
            throw GitError.gitUnavailable(error.localizedDescription)
        }

        if let stdin, let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        // Читаем оба пайпа параллельно ДО waitUntilExit — иначе процесс с
        // большим выводом заблокируется на полном буфере пайпа (deadlock).
        var outData = Data()
        var errData = Data()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        // Сторожевой таймер: зависший git (сеть, запрос пароля) убиваем —
        // читатели получат EOF, waitUntilExit вернётся.
        var timedOut = false
        let watchdog = DispatchWorkItem {
            timedOut = true
            process.sendKillSignal()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        readers.wait()

        return RunResult(exitCode: process.terminationStatus,
                         stdout: String(data: outData, encoding: .utf8) ?? "",
                         stderr: String(data: errData, encoding: .utf8) ?? "",
                         timedOut: timedOut)
    }
}
