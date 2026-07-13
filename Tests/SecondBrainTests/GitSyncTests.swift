// GitSyncTests.swift — тесты git-синхронизации (задача 16).
//
// Два слоя:
//  - чистые: парсер status porcelain v2, парсер log, детект токена в URL,
//    логика авто-бэкапа (мок-часы), советчик .gitignore — без запуска git;
//  - интеграционные: реальный git CLI на temp-репозиториях (допустимо по
//    критериям задачи) — commit+log round-trip, ahead/behind через bare
//    remote, конфликт pull → abort → чистый статус.

import XCTest
@testable import SecondBrain

// MARK: - Чистые тесты: парсер status

final class GitStatusParserTests: XCTestCase {

    func testParsesBranchHeaders() {
        let out = """
        # branch.oid 1234567890abcdef
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -3
        """
        let status = GitStatusParser.parse(out)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 3)
        XCTAssertTrue(status.isClean)
    }

    func testParsesChangeKinds() {
        // Пути с пробелами — типичны для vault («Новая заметка.md»).
        let out = """
        # branch.head main
        1 .M N... 100644 100644 100644 aaaa bbbb Заметки/Новая заметка.md
        1 A. N... 000000 100644 100644 0000 cccc добавленный.md
        1 .D N... 100644 100644 000000 dddd eeee удалённый.md
        2 R. N... 100644 100644 100644 ffff gggg R100 новое имя.md\tстарое имя.md
        ? untracked заметка.md
        """
        let status = GitStatusParser.parse(out)
        XCTAssertEqual(status.changes.count, 5)
        XCTAssertEqual(status.changes[0], GitFileChange(path: "Заметки/Новая заметка.md", kind: .modified))
        XCTAssertEqual(status.changes[1].kind, .added)
        XCTAssertEqual(status.changes[2].kind, .deleted)
        XCTAssertEqual(status.changes[3], GitFileChange(path: "новое имя.md", kind: .renamed))
        XCTAssertEqual(status.changes[4], GitFileChange(path: "untracked заметка.md", kind: .untracked))
    }

    func testParsesConflictedFiles() {
        let out = """
        # branch.head main
        u UU N... 100644 100644 100644 100644 aaaa bbbb cccc Общая заметка.md
        """
        let status = GitStatusParser.parse(out)
        XCTAssertEqual(status.conflicted, ["Общая заметка.md"])
        XCTAssertFalse(status.isClean)
    }

    func testEmptyOutputIsCleanWithoutBranch() {
        let status = GitStatusParser.parse("")
        XCTAssertTrue(status.isClean)
        XCTAssertNil(status.branch)
        XCTAssertEqual(status.ahead, 0)
    }
}

// MARK: - Чистые тесты: детект токена в URL remote

final class GitRemoteURLTests: XCTestCase {

    func testDetectsBareTokenInHTTPSURL() {
        let url = "https://ghp_abc123XYZ@github.com/user/vault.git"
        XCTAssertEqual(GitRemoteURL.embeddedCredential(in: url), "ghp_abc123XYZ")
        XCTAssertEqual(GitRemoteURL.strippingCredential(url),
                       "https://github.com/user/vault.git")
    }

    func testDetectsUserColonTokenInHTTPSURL() {
        let url = "https://user:s3cret@github.com/user/vault.git"
        XCTAssertEqual(GitRemoteURL.embeddedCredential(in: url), "user:s3cret")
        XCTAssertEqual(GitRemoteURL.strippingCredential(url),
                       "https://github.com/user/vault.git")
    }

    func testCleanHTTPSURLHasNoCredential() {
        XCTAssertNil(GitRemoteURL.embeddedCredential(in: "https://github.com/user/vault.git"))
    }

    func testSSHURLsAreNotFlagged() {
        // «git@» в ssh — логин подключения, не секрет.
        XCTAssertNil(GitRemoteURL.embeddedCredential(in: "git@github.com:user/vault.git"))
        XCTAssertNil(GitRemoteURL.embeddedCredential(in: "ssh://git@github.com/user/vault.git"))
    }

    func testAtSignInPathIsNotUserinfo() {
        XCTAssertNil(GitRemoteURL.embeddedCredential(in: "https://host.com/path/with@sign.git"))
    }

    func testStrippingLeavesCleanURLUntouched() {
        let clean = "https://github.com/user/vault.git"
        XCTAssertEqual(GitRemoteURL.strippingCredential(clean), clean)
    }
}

// MARK: - Чистые тесты: авто-бэкап (мок-часы)

final class AutoBackupTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_760_000_000)

    func testCommitMessageMatchesUserFormat() {
        // Формат «vault backup: YYYY-MM-DD HH:mm:ss» — как в истории vault.
        let msk = TimeZone(identifier: "Europe/Moscow")!
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 1
        components.hour = 20; components.minute = 42; components.second = 14
        components.timeZone = msk
        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(AutoBackup.commitMessage(for: date, timeZone: msk),
                       "vault backup: 2026-07-01 20:42:14")
    }

    func testIsDueRespectsIntervalAndMockClock() {
        // Выключен (0) — никогда.
        XCTAssertFalse(AutoBackup.isDue(now: noon, lastAttempt: nil, interval: 0))
        // Первая попытка — сразу.
        XCTAssertTrue(AutoBackup.isDue(now: noon, lastAttempt: nil, interval: 300))
        // Рано: прошло 100 c из 300.
        XCTAssertFalse(AutoBackup.isDue(now: noon.addingTimeInterval(100),
                                        lastAttempt: noon, interval: 300))
        // Пора: прошло ровно 300 с.
        XCTAssertTrue(AutoBackup.isDue(now: noon.addingTimeInterval(300),
                                       lastAttempt: noon, interval: 300))
    }

    func testPlanNoChangesMakesNoCommit() {
        // Критерий приёмки: нет изменений → нет коммита (и пуша).
        var status = GitStatus()
        status.branch = "main"
        XCTAssertEqual(AutoBackup.plan(status: status, hasRemote: true), .nothing)
    }

    func testPlanChangesCommitAndPush() {
        var status = GitStatus()
        status.changes = [GitFileChange(path: "a.md", kind: .modified)]
        let plan = AutoBackup.plan(status: status, hasRemote: true)
        XCTAssertTrue(plan.needsCommit)
        XCTAssertTrue(plan.needsPush)
    }

    func testPlanRetryAfterFailedPushDoesNotDuplicateCommit() {
        // Прошлый прогон закоммитил, но push упал: изменений нет, ahead > 0 —
        // только допушиваем, второй коммит не создаётся.
        var status = GitStatus()
        status.ahead = 1
        let plan = AutoBackup.plan(status: status, hasRemote: true)
        XCTAssertFalse(plan.needsCommit)
        XCTAssertTrue(plan.needsPush)
    }

    func testPlanWithoutRemoteOnlyCommits() {
        var status = GitStatus()
        status.changes = [GitFileChange(path: "a.md", kind: .modified)]
        let plan = AutoBackup.plan(status: status, hasRemote: false)
        XCTAssertTrue(plan.needsCommit)
        XCTAssertFalse(plan.needsPush)
    }

    func testPlanSkipsConflictedState() {
        var status = GitStatus()
        status.conflicted = ["a.md"]
        status.changes = [GitFileChange(path: "a.md", kind: .modified)]
        XCTAssertEqual(AutoBackup.plan(status: status, hasRemote: true), .nothing)
    }
}

// MARK: - Чистые тесты: .gitignore

final class GitignoreAdvisorTests: XCTestCase {

    func testMissingEntriesOnEmptyFile() {
        XCTAssertEqual(GitignoreAdvisor.missingEntries(in: ""),
                       [".obsidian/workspace*", ".DS_Store", "Meetings/_recordings/"])
    }

    func testExistingEntriesNotSuggested() {
        let content = ".DS_Store\n.obsidian/workspace*\n"
        XCTAssertEqual(GitignoreAdvisor.missingEntries(in: content),
                       ["Meetings/_recordings/"])
    }

    func testAppendingPreservesOriginalContent() {
        let appended = GitignoreAdvisor.appending([".DS_Store"], to: "existing.md")
        XCTAssertTrue(appended.hasPrefix("existing.md\n"))
        XCTAssertTrue(appended.contains(".DS_Store\n"))
    }

    func testAppendingNothingKeepsContentIdentical() {
        XCTAssertEqual(GitignoreAdvisor.appending([], to: "x\n"), "x\n")
    }
}

// MARK: - Интеграционные тесты (реальный git CLI)

final class GitClientIntegrationTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(GitClient.detectGitPath() == nil, "git не найден")
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitsync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    /// URL репозитория по имени (repoURL актора снаружи не читается синхронно).
    private func repoURL(_ name: String) -> URL {
        tempRoot.appendingPathComponent(name)
    }

    /// Новый инициализированный репозиторий с тестовой identity (иначе commit
    /// падает на машинах без глобального user.name).
    private func makeRepo(named name: String) async throws -> GitClient {
        let url = repoURL(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let client = GitClient(repoURL: url)
        try await client.initRepository()
        try await client.configSet("user.name", "Test")
        try await client.configSet("user.email", "test@example.com")
        try await client.configSet("commit.gpgsign", "false")
        return client
    }

    private func write(_ text: String, to file: String, inRepo name: String) throws {
        try text.write(to: repoURL(name).appendingPathComponent(file),
                       atomically: true, encoding: .utf8)
    }

    func testIsRepositoryDetection() async throws {
        let plain = tempRoot.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let notRepo = GitClient(repoURL: plain)
        let isRepoBefore = await notRepo.isRepository()
        XCTAssertFalse(isRepoBefore)

        let repo = try await makeRepo(named: "repo")
        let isRepoAfter = await repo.isRepository()
        XCTAssertTrue(isRepoAfter)

        // Подпапка чужого репозитория — НЕ репозиторий vault (защита от
        // коммита родительского репо целиком).
        let nested = repoURL("repo").appendingPathComponent("вложенная")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedClient = GitClient(repoURL: nested)
        let nestedIsRepo = await nestedClient.isRepository()
        XCTAssertFalse(nestedIsRepo)
    }

    func testCommitLogRoundTripAndNoDuplicateCommit() async throws {
        let repo = try await makeRepo(named: "roundtrip")
        try write("# Заметка", to: "заметка.md", inRepo: "roundtrip")

        let committed = try await repo.commitAll(message: "vault backup: 2026-07-13 10:00:00")
        XCTAssertTrue(committed)

        // Без изменений commitAll не создаёт пустой коммит.
        let again = try await repo.commitAll(message: "не должен появиться")
        XCTAssertFalse(again)

        let log = try await repo.log(limit: 10)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].subject, "vault backup: 2026-07-13 10:00:00")
        XCTAssertEqual(log[0].author, "Test")

        let status = try await repo.status()
        XCTAssertTrue(status.isClean)
    }

    func testStatusSeesChangesAndUntracked() async throws {
        let repo = try await makeRepo(named: "status")
        try write("v1", to: "существующая.md", inRepo: "status")
        _ = try await repo.commitAll(message: "base")

        try write("v2", to: "существующая.md", inRepo: "status")
        try write("новая", to: "новая заметка.md", inRepo: "status")

        let status = try await repo.status()
        XCTAssertEqual(status.changes.count, 2)
        XCTAssertTrue(status.changes.contains(GitFileChange(path: "существующая.md", kind: .modified)))
        XCTAssertTrue(status.changes.contains(GitFileChange(path: "новая заметка.md", kind: .untracked)))
    }

    /// Два клона одного bare-remote: расхождение даёт ahead/behind.
    func testAheadBehindBetweenTwoClones() async throws {
        let bare = tempRoot.appendingPathComponent("remote.git")
        let bareClient = GitClient(repoURL: tempRoot)
        try await bareClient.raw(["init", "--bare", bare.path])

        let a = try await makeRepo(named: "a")
        try write("база", to: "база.md", inRepo: "a")
        _ = try await a.commitAll(message: "base")
        try await a.addRemote(name: "origin", url: bare.path)
        try await a.push() // без upstream → фолбэк push -u origin HEAD

        // B — клон remote.
        let bURL = tempRoot.appendingPathComponent("b")
        try await bareClient.raw(["clone", bare.path, bURL.path])
        let b = GitClient(repoURL: bURL)
        try await b.configSet("user.name", "Test B")
        try await b.configSet("user.email", "b@example.com")
        try await b.configSet("commit.gpgsign", "false")

        // A: новый коммит + push; B: свой локальный коммит.
        try write("от A", to: "от-a.md", inRepo: "a")
        _ = try await a.commitAll(message: "from A")
        try await a.push()
        try write("от B", to: "от-b.md", inRepo: "b")
        _ = try await b.commitAll(message: "from B")

        try await b.fetch()
        let status = try await b.status()
        XCTAssertEqual(status.ahead, 1)
        XCTAssertEqual(status.behind, 1)
    }

    /// Конфликт pull: merge прерывается, статус остаётся чистым, данные целы.
    func testPullConflictAbortsAndLeavesCleanState() async throws {
        let bare = tempRoot.appendingPathComponent("remote.git")
        let bareClient = GitClient(repoURL: tempRoot)
        try await bareClient.raw(["init", "--bare", bare.path])

        let a = try await makeRepo(named: "a")
        try write("общая строка", to: "общая.md", inRepo: "a")
        _ = try await a.commitAll(message: "base")
        try await a.addRemote(name: "origin", url: bare.path)
        try await a.push()

        let bURL = tempRoot.appendingPathComponent("b")
        try await bareClient.raw(["clone", bare.path, bURL.path])
        let b = GitClient(repoURL: bURL)
        try await b.configSet("user.name", "Test B")
        try await b.configSet("user.email", "b@example.com")
        try await b.configSet("commit.gpgsign", "false")

        // Обе стороны правят одну строку одного файла.
        try write("версия A", to: "общая.md", inRepo: "a")
        _ = try await a.commitAll(message: "edit A")
        try await a.push()
        try write("версия B", to: "общая.md", inRepo: "b")
        _ = try await b.commitAll(message: "edit B")

        do {
            try await b.pull()
            XCTFail("pull обязан упасть с конфликтом")
        } catch let error as GitError {
            guard case .mergeConflict(let files) = error else {
                return XCTFail("ожидали mergeConflict, получили \(error)")
            }
            XCTAssertEqual(files, ["общая.md"])
        }

        // После abort: рабочая копия чистая, merge не в процессе, локальная
        // версия файла не потеряна.
        let status = try await b.status()
        XCTAssertTrue(status.conflicted.isEmpty)
        XCTAssertTrue(status.changes.isEmpty)
        let content = try String(contentsOf: bURL.appendingPathComponent("общая.md"),
                                 encoding: .utf8)
        XCTAssertEqual(content, "версия B")

        // Разрешение «принять свои»: pull -X ours проходит без конфликта.
        try await b.pull(resolving: .ours)
        let resolved = try String(contentsOf: bURL.appendingPathComponent("общая.md"),
                                  encoding: .utf8)
        XCTAssertEqual(resolved, "версия B")
    }

    func testRemotesParsingAndSetURL() async throws {
        let repo = try await makeRepo(named: "remotes")
        try await repo.addRemote(name: "origin", url: "https://token123@github.com/u/r.git")
        var remotes = try await repo.remotes()
        XCTAssertEqual(remotes, [GitRemote(name: "origin",
                                           url: "https://token123@github.com/u/r.git")])

        // Починка URL: тот же remote без токена.
        let clean = GitRemoteURL.strippingCredential(remotes[0].url)
        try await repo.setRemoteURL(name: "origin", url: clean)
        remotes = try await repo.remotes()
        XCTAssertEqual(remotes[0].url, "https://github.com/u/r.git")
    }
}
