// ChatChangesTests.swift — тесты вкладки «Изменения» (задача 40).
//
// Чистая логика: разбиение git-diff'а по файлам (DiffSplitter), агрегация
// операций агента по сообщениям чата. Интеграция: GitChangesOverview.load
// на реальном temp-репозитории (паттерн GitToolsIntegrationTests) — статус,
// незакоммиченный diff, отличия ветки от main, чистое дерево.

import XCTest
@testable import SecondBrain

final class DiffSplitterTests: XCTestCase {

    func testSplitsMultiFileGitDiff() {
        let diff = """
        diff --git a/a.md b/a.md
        index 111..222 100644
        --- a/a.md
        +++ b/a.md
        @@ -1,2 +1,2 @@
        -старая
        +новая
         контекст
        diff --git a/docs/b.md b/docs/b.md
        --- a/docs/b.md
        +++ b/docs/b.md
        @@ -1 +1,2 @@
         строка
        +добавка
        """
        let sections = DiffSplitter.split(diff)
        XCTAssertEqual(sections.map(\.path), ["a.md", "docs/b.md"])
        XCTAssertEqual(sections[0].added, 1)
        XCTAssertEqual(sections[0].removed, 1)
        XCTAssertEqual(sections[1].added, 1)
        XCTAssertEqual(sections[1].removed, 0)
        XCTAssertTrue(sections[0].text.contains("-старая"))
        XCTAssertFalse(sections[0].text.contains("добавка"))
        XCTAssertEqual(sections[1].badge, "+1 −0")
    }

    /// Diff нашего UnifiedDiff (без «diff --git») — одна секция, путь из «+++».
    func testSplitsPlainUnifiedDiff() {
        let diff = UnifiedDiff.make(path: "note.md", old: "a\n", new: "b\n").text
        let sections = DiffSplitter.split(diff)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].path, "note.md")
        XCTAssertEqual(sections[0].added, 1)
        XCTAssertEqual(sections[0].removed, 1)
    }

    func testEmptyDiffGivesNoSections() {
        XCTAssertTrue(DiffSplitter.split("").isEmpty)
        XCTAssertTrue(DiffSplitter.split("  \n ").isEmpty)
    }
}

final class ChatChangesAggregatorTests: XCTestCase {

    func testAggregatesNewestFirst() {
        var first = ChatMessage(role: .assistant, content: "ход 1")
        first.fileChanges = [
            FileChangeDisplay(relativePath: "a.md", kind: .created, diff: "+a"),
            FileChangeDisplay(relativePath: "b.md", kind: .modified, diff: "+b")
        ]
        var second = ChatMessage(role: .assistant, content: "ход 2")
        second.fileChanges = [
            FileChangeDisplay(relativePath: "c.md", kind: .deleted, diff: "(удалён)")
        ]
        let plain = ChatMessage(role: .user, content: "без изменений")

        let entries = ChatChangesAggregator.agentChanges(messages: [first, plain, second])
        XCTAssertEqual(entries.map(\.change.relativePath), ["c.md", "b.md", "a.md"],
                       "новые операции сверху")
    }

    func testEmptyMessagesGiveNoEntries() {
        XCTAssertTrue(ChatChangesAggregator.agentChanges(messages: []).isEmpty)
        XCTAssertTrue(ChatChangesAggregator.agentChanges(
            messages: [ChatMessage(role: .assistant, content: "текст")]).isEmpty)
    }
}

final class GitChangesOverviewTests: XCTestCase {

    private var tempRoot: URL!
    private var repoRoot: URL!
    private var git: GitClient!

    override func setUp() async throws {
        try XCTSkipIf(GitClient.detectGitPath() == nil, "git не найден")
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-changes-\(UUID().uuidString)")
        repoRoot = tempRoot.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        git = GitClient(repoURL: repoRoot)
        try await git.initRepository()
        try await git.configSet("user.name", "Test")
        try await git.configSet("user.email", "test@example.com")
        try await git.configSet("commit.gpgsign", "false")
        try "первая\n".write(to: repoRoot.appendingPathComponent("a.md"),
                             atomically: true, encoding: .utf8)
        _ = try await git.commitAll(message: "начало")
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    func testNonRepoFolder() async throws {
        let plain = tempRoot.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let overview = await GitChangesOverview.load(git: GitClient(repoURL: plain))
        XCTAssertFalse(overview.isRepo)
    }

    func testCleanTree() async {
        let overview = await GitChangesOverview.load(git: git)
        XCTAssertTrue(overview.isRepo)
        XCTAssertNotNil(overview.branch)
        XCTAssertTrue(overview.isClean, "\(overview.files)")
        XCTAssertNil(overview.baseBranch, "на базовой ветке секции отличий нет")
    }

    func testUncommittedChangesAppearInDiff() async throws {
        try "правка\n".write(to: repoRoot.appendingPathComponent("a.md"),
                             atomically: true, encoding: .utf8)
        let overview = await GitChangesOverview.load(git: git)
        XCTAssertEqual(overview.files.map(\.path), ["a.md"])
        XCTAssertTrue(overview.diff.contains("+правка"), overview.diff)
        XCTAssertFalse(overview.isClean)
    }

    /// На фиче-ветке появляется секция отличий от базовой (main/master).
    func testBranchDiffAgainstBase() async throws {
        let base = (try await git.branches()).current ?? "main"
        _ = try await git.raw(["checkout", "-b", "feature"])
        try "фича\n".write(to: repoRoot.appendingPathComponent("f.md"),
                           atomically: true, encoding: .utf8)
        _ = try await git.commitAll(message: "фича-коммит")

        let overview = await GitChangesOverview.load(git: git)
        XCTAssertEqual(overview.branch, "feature")
        XCTAssertEqual(overview.baseBranch, base)
        XCTAssertTrue(overview.baseDiff.contains("+фича"), overview.baseDiff)
        XCTAssertTrue(overview.isClean, "рабочее дерево после коммита чистое")
    }

    /// commitAll — путь кнопки «Закоммитить» вкладки: дерево чистеет.
    func testCommitAllClearsTree() async throws {
        try "ещё\n".write(to: repoRoot.appendingPathComponent("new.md"),
                          atomically: true, encoding: .utf8)
        let committed = try await git.commitAll(message: "из вкладки изменений")
        XCTAssertTrue(committed)
        let overview = await GitChangesOverview.load(git: git)
        XCTAssertTrue(overview.isClean)
        let log = try await git.log(limit: 1)
        XCTAssertEqual(log.first?.subject, "из вкладки изменений")
    }
}
