// ToolPermissionsTests.swift — тесты слоя разрешений (задача 39).
//
// Классификатор и матрица «режим × риск» — чистые функции, проверяются
// исчерпывающе: каждый встроенный инструмент, MCP-имена, allowlist команд
// (включая составные через && ; | и редиректы), конфиг-пути, ключи операций.

import XCTest
@testable import SecondBrain

final class ToolRiskClassifierTests: XCTestCase {

    func testSafeBuiltinsAreSafe() {
        for name in ["read_file", "list_files", "search_files",
                     "git_branches", "git_status", "git_log", "git_diff",
                     "rag_search"] {
            XCTAssertEqual(ToolRiskClassifier.classify(name: name, argumentsJSON: "{}"),
                           .safe, name)
        }
    }

    func testWriteToolsAreWriteLevel() {
        XCTAssertEqual(ToolRiskClassifier.classify(
            name: "write_file", argumentsJSON: #"{"path":"notes/a.md"}"#), .write)
        XCTAssertEqual(ToolRiskClassifier.classify(
            name: "edit_file", argumentsJSON: #"{"path":"src/App.swift"}"#), .write)
    }

    /// Правка скрытых файлов/папок (конфиги) — опасная, не обычная.
    func testConfigPathWritesAreDangerous() {
        for path in [".env", ".git/config", ".github/workflows/ci.yml", "a/.hidden/x"] {
            XCTAssertEqual(ToolRiskClassifier.classify(
                name: "write_file", argumentsJSON: #"{"path":"\#(path)"}"#),
                .dangerous, path)
        }
        XCTAssertTrue(ToolRiskClassifier.isConfigPath(".env"))
        XCTAssertFalse(ToolRiskClassifier.isConfigPath("docs/readme.md"))
        // Точка внутри имени — не скрытый файл.
        XCTAssertFalse(ToolRiskClassifier.isConfigPath("a.b/file.md"))
    }

    func testDeleteIsAlwaysDangerous() {
        XCTAssertEqual(ToolRiskClassifier.classify(
            name: "delete_file", argumentsJSON: #"{"path":"a.md"}"#), .dangerous)
    }

    /// MCP-инструменты (qualified «slug__tool») — write-уровень: побочный
    /// эффект неизвестен (закрывает BACKLOG п. 10).
    func testMCPToolsAreWriteLevel() {
        XCTAssertEqual(ToolRiskClassifier.classify(
            name: "atlassian__createJiraIssue", argumentsJSON: "{}"), .write)
        XCTAssertEqual(ToolRiskClassifier.classify(
            name: "git__git_status", argumentsJSON: "{}"), .write)
    }

    func testUnknownToolIsDangerous() {
        XCTAssertEqual(ToolRiskClassifier.classify(name: "mystery", argumentsJSON: "{}"),
                       .dangerous)
    }

    // MARK: - run_command

    func testSafeCommands() {
        for command in ["swift build", "swift test",
                        "git status", "git log -n 5", "git diff --stat",
                        "ls -la", "cat README.md", "grep -r TODO Sources",
                        "swift build && swift test"] {
            XCTAssertEqual(ToolRiskClassifier.classifyCommand(command), .safe, command)
        }
    }

    func testDangerousCommands() {
        for command in ["git push", "git push --force", "rm -rf /",
                        "curl https://example.com", "./script.sh",
                        "python3 hack.py", "sudo rm x", "",
                        "swift test && git push",       // опасная часть в цепочке
                        "git log; rm -rf .",            // разделитель ;
                        "ls | sh",                      // pipe в опасное
                        "ls > files.txt",               // редирект пишет файл
                        "cat `whoami`",                 // подстановка команд
                        "git log --output=evil"] {      // git пишет файл
            XCTAssertEqual(ToolRiskClassifier.classifyCommand(command), .dangerous, command)
        }
    }

    func testRunCommandClassifiedThroughArguments() {
        XCTAssertEqual(ToolRiskClassifier.classify(
            name: "run_command", argumentsJSON: #"{"command":"swift test"}"#), .safe)
        XCTAssertEqual(ToolRiskClassifier.classify(
            name: "run_command", argumentsJSON: #"{"command":"git push"}"#), .dangerous)
        // Нет команды → опасно (защитный дефолт).
        XCTAssertEqual(ToolRiskClassifier.classify(
            name: "run_command", argumentsJSON: "{}"), .dangerous)
    }

    // MARK: - Ключи операций (allowlist «на сессию»)

    func testOperationKeys() {
        XCTAssertEqual(ToolRiskClassifier.operationKey(
            name: "delete_file", argumentsJSON: #"{"path":"a.md"}"#), "delete_file")
        // run_command — нормализованная команда целиком.
        XCTAssertEqual(ToolRiskClassifier.operationKey(
            name: "run_command", argumentsJSON: #"{"command":"  git   push  "}"#),
            "run_command:git push")
    }
}

final class ToolPermissionPolicyTests: XCTestCase {

    /// Матрица «режим × риск»: спрашивать — правки и опасное; авто — только
    /// опасное; авто-опасный — ничего.
    func testModeRiskMatrix() {
        typealias P = ToolPermissionPolicy
        XCTAssertFalse(P.requiresApproval(mode: .ask, risk: .safe))
        XCTAssertTrue(P.requiresApproval(mode: .ask, risk: .write))
        XCTAssertTrue(P.requiresApproval(mode: .ask, risk: .dangerous))

        XCTAssertFalse(P.requiresApproval(mode: .auto, risk: .safe))
        XCTAssertFalse(P.requiresApproval(mode: .auto, risk: .write))
        XCTAssertTrue(P.requiresApproval(mode: .auto, risk: .dangerous))

        XCTAssertFalse(P.requiresApproval(mode: .autoDanger, risk: .safe))
        XCTAssertFalse(P.requiresApproval(mode: .autoDanger, risk: .write))
        XCTAssertFalse(P.requiresApproval(mode: .autoDanger, risk: .dangerous))
    }

    /// Незнакомый режим «из будущего» декодируется в самый строгий (ask).
    func testUnknownModeDecodesToAsk() throws {
        let decoded = try JSONDecoder().decode(AgentPermissionMode.self,
                                               from: Data("\"turbo\"".utf8))
        XCTAssertEqual(decoded, .ask)
    }
}
