// UnifiedDiffTests.swift — тесты diff-утилиты (задача 39).
//
// UnifiedDiff — чистая функция: старое/новое содержимое → unified diff.
// Проверяются: создание/удаление файла, идентичные тексты, замена, вставка
// и удаление строк, несколько hunks, файлы без завершающего \n, капы.

import XCTest
@testable import SecondBrain

final class UnifiedDiffTests: XCTestCase {

    func testNewFileAllAdded() {
        let result = UnifiedDiff.make(path: "a.md", old: nil, new: "один\nдва\n")
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.removed, 0)
        XCTAssertTrue(result.text.contains("--- /dev/null"), result.text)
        XCTAssertTrue(result.text.contains("+++ b/a.md"), result.text)
        XCTAssertTrue(result.text.contains("+один"), result.text)
        XCTAssertTrue(result.text.contains("+два"), result.text)
    }

    func testDeletedFileAllRemoved() {
        let result = UnifiedDiff.make(path: "a.md", old: "один\nдва\n", new: nil)
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.removed, 2)
        XCTAssertTrue(result.text.contains("+++ /dev/null"), result.text)
        XCTAssertTrue(result.text.contains("-один"), result.text)
    }

    func testIdenticalTextsGiveEmptyDiff() {
        let text = "один\nдва\nтри\n"
        let result = UnifiedDiff.make(path: "a.md", old: text, new: text)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.text, "")
    }

    func testSingleLineReplacement() {
        let old = "один\nдва\nтри\n"
        let new = "один\nДВА\nтри\n"
        let result = UnifiedDiff.make(path: "a.md", old: old, new: new)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.removed, 1)
        XCTAssertTrue(result.text.contains("-два"), result.text)
        XCTAssertTrue(result.text.contains("+ДВА"), result.text)
        // Контекст вокруг замены.
        XCTAssertTrue(result.text.contains(" один"), result.text)
        XCTAssertTrue(result.text.contains(" три"), result.text)
    }

    func testInsertionAndDeletion() {
        let old = "a\nb\nc\n"
        let new = "a\nc\nd\n"
        let result = UnifiedDiff.make(path: "f", old: old, new: new)
        XCTAssertEqual(result.removed, 1) // b
        XCTAssertEqual(result.added, 1)   // d
        XCTAssertTrue(result.text.contains("-b"), result.text)
        XCTAssertTrue(result.text.contains("+d"), result.text)
    }

    /// Два далёких изменения в большом файле → два отдельных hunk'а.
    func testTwoDistantChangesGiveTwoHunks() {
        var oldLines = (1...40).map { "строка \($0)" }
        var newLines = oldLines
        newLines[2] = "правка A"
        newLines[36] = "правка B"
        let result = UnifiedDiff.make(path: "f",
                                      old: oldLines.joined(separator: "\n") + "\n",
                                      new: newLines.joined(separator: "\n") + "\n")
        let hunkCount = result.text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("@@") }.count
        XCTAssertEqual(hunkCount, 2, result.text)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.removed, 2)
    }

    /// Файл без завершающего \n: изменение только «появился \n в конце»
    /// не должно считаться равенством — и помечается стандартной строкой.
    func testTrailingNewlineDifferenceDetected() {
        let result = UnifiedDiff.make(path: "f", old: "a\nb", new: "a\nb\n")
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.text.contains("\\ No newline at end of file"), result.text)
    }

    func testNoTrailingNewlineBothSidesEqual() {
        let result = UnifiedDiff.make(path: "f", old: "a\nb", new: "a\nb")
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyToContent() {
        let result = UnifiedDiff.make(path: "f", old: "", new: "x\n")
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.removed, 0)
    }

    /// Гигантский файл → честный фолбэк без LCS.
    func testHugeFileFallsBack() {
        let old = Array(repeating: "x", count: UnifiedDiff.maxLines + 1)
            .joined(separator: "\n") + "\n"
        let result = UnifiedDiff.make(path: "f", old: old, new: "y\n")
        XCTAssertTrue(result.text.contains("файл заменён целиком"), result.text)
    }

    /// Номера строк в заголовке hunk'а — 1-based и соответствуют diff -u.
    func testHunkHeaderNumbers() {
        let old = "a\nb\nc\n"
        let new = "a\nB\nc\n"
        let result = UnifiedDiff.make(path: "f", old: old, new: new)
        XCTAssertTrue(result.text.contains("@@ -1,3 +1,3 @@"), result.text)
    }

    func testSummaryFormat() {
        let result = UnifiedDiff.make(path: "f", old: "a\n", new: "b\nc\n")
        XCTAssertEqual(result.summary, "+2/−1 строк")
    }
}
