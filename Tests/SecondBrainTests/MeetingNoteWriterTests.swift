// MeetingNoteWriterTests.swift — генерация пути заметки (кириллица, коллизии),
// чистка названия, валидация папки от LLM, содержимое заметки.

import XCTest
@testable import SecondBrain

final class MeetingNoteWriterTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_783_000_000) // июль 2026

    // MARK: - Название

    func testSanitizeKeepsCyrillic() {
        XCTAssertEqual(MeetingNoteWriter.sanitizeTitle("Синк по релизу 3.2"),
                       "Синк по релизу 3.2")
    }

    func testSanitizeReplacesForbiddenCharacters() {
        // Висячие дефисы/точки на конце подрезаются — имя выходит опрятным.
        XCTAssertEqual(MeetingNoteWriter.sanitizeTitle("Обсуждение: план/факт | Q3?"),
                       "Обсуждение- план-факт - Q3")
        XCTAssertFalse(MeetingNoteWriter.sanitizeTitle("a\\b:c*d?e\"f<g>h|i").contains(where: {
            "/\\:*?\"<>|".contains($0)
        }))
    }

    func testSanitizeEmptyFallsBack() {
        XCTAssertEqual(MeetingNoteWriter.sanitizeTitle("   "), "Встреча")
        XCTAssertEqual(MeetingNoteWriter.sanitizeTitle("///"), "Встреча")
    }

    func testSanitizeCapsLength() {
        let long = String(repeating: "щ", count: 300)
        XCTAssertLessThanOrEqual(MeetingNoteWriter.sanitizeTitle(long).count, 80)
    }

    // MARK: - Папка

    func testResolveFolderAcceptsExisting() {
        let (folder, invalid) = MeetingNoteWriter.resolveFolder(
            suggested: "Работа/Релизы",
            existingFolders: ["Работа", "Работа/Релизы"],
            date: date)
        XCTAssertEqual(folder, "Работа/Релизы")
        XCTAssertFalse(invalid)
    }

    func testResolveFolderFallsBackOnUnknown() {
        let (folder, invalid) = MeetingNoteWriter.resolveFolder(
            suggested: "Выдуманная/Папка",
            existingFolders: ["Работа"],
            date: date)
        XCTAssertEqual(folder, MeetingNoteWriter.defaultFolder(for: date))
        XCTAssertTrue(invalid, "пользователь должен увидеть, что папку заменили")
    }

    func testResolveFolderEmptyIsDefaultNotInvalid() {
        let (folder, invalid) = MeetingNoteWriter.resolveFolder(
            suggested: nil, existingFolders: [], date: date)
        XCTAssertEqual(folder, MeetingNoteWriter.defaultFolder(for: date))
        XCTAssertFalse(invalid)
    }

    func testResolveFolderMeetingsSubfolderAlwaysLegal() {
        // Дефолтное дерево Meetings/YYYY-MM может ещё не существовать.
        let (folder, invalid) = MeetingNoteWriter.resolveFolder(
            suggested: "Meetings/2026-07", existingFolders: [], date: date)
        XCTAssertEqual(folder, "Meetings/2026-07")
        XCTAssertFalse(invalid)
    }

    // MARK: - Путь заметки

    func testNotePathFormat() {
        let path = MeetingNoteWriter.notePath(folder: "Meetings/2026-07",
                                              date: date,
                                              title: "Синк по релизу",
                                              exists: { _ in false })
        XCTAssertTrue(path.hasPrefix("Meetings/2026-07/"))
        XCTAssertTrue(path.hasSuffix(" Синк по релизу.md"))
        // Дата в имени: YYYY-MM-DD.
        let name = path.components(separatedBy: "/").last!
        XCTAssertNotNil(name.range(of: #"^\d{4}-\d{2}-\d{2} "#, options: .regularExpression))
    }

    func testNotePathResolvesCollisions() {
        var taken: Set<String> = []
        let first = MeetingNoteWriter.notePath(folder: "F", date: date, title: "Встреча",
                                               exists: { taken.contains($0) })
        taken.insert(first)
        let second = MeetingNoteWriter.notePath(folder: "F", date: date, title: "Встреча",
                                                exists: { taken.contains($0) })
        taken.insert(second)
        let third = MeetingNoteWriter.notePath(folder: "F", date: date, title: "Встреча",
                                               exists: { taken.contains($0) })
        XCTAssertTrue(second.hasSuffix(" (2).md"))
        XCTAssertTrue(third.hasSuffix(" (3).md"))
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Содержимое

    func testNoteContentStructure() {
        var context = MeetingContext(recordingBase: "2026-07-12 10-30",
                                     audioFiles: ["2026-07-12 10-30.m4a",
                                                  "2026-07-12 10-30 (система).m4a"],
                                     recordedAt: date,
                                     duration: 1935) // 32 мин 15 с
        context.summary = "Ключевые решения."
        context.transcriptionProviderID = "openai"
        context.suggestedTitle = "Синк по релизу"
        context.transcripts = [
            TrackTranscript(fileName: "2026-07-12 10-30.m4a",
                            transcript: Transcript(fullText: "привет всем",
                                                   segments: [TranscriptSegment(text: "привет всем",
                                                                                start: 0, end: 2)],
                                                   language: "ru")),
            TrackTranscript(fileName: "2026-07-12 10-30 (система).m4a",
                            transcript: Transcript(fullText: "и вам привет",
                                                   segments: [TranscriptSegment(text: "и вам привет",
                                                                                start: 65, end: 67)],
                                                   language: "ru"))
        ]
        let content = MeetingNoteWriter.noteContent(context: context)

        XCTAssertTrue(content.hasPrefix("---\n"), "frontmatter первым")
        XCTAssertTrue(content.contains("duration: 32 мин"))
        XCTAssertTrue(content.contains("transcription: openai"))
        XCTAssertTrue(content.contains("- \"[[2026-07-12 10-30.m4a]]\""), "ссылка на аудио")
        XCTAssertTrue(content.contains("# Синк по релизу"))
        XCTAssertTrue(content.contains("## Саммари"))
        XCTAssertTrue(content.contains("## Транскрипт"))
        XCTAssertTrue(content.contains("### Микрофон"), "две дорожки — секции")
        XCTAssertTrue(content.contains("### Собеседники (система)"))
        XCTAssertTrue(content.contains("[00:00] привет всем"), "таймкоды")
        XCTAssertTrue(content.contains("[01:05] и вам привет"))
    }

    func testWriteRefusesOverwrite() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try MeetingNoteWriter.write(content: "первая", relativePath: "A/заметка.md",
                                        vaultURL: tempDir)
        XCTAssertThrowsError(try MeetingNoteWriter.write(content: "вторая",
                                                         relativePath: "A/заметка.md",
                                                         vaultURL: tempDir),
                             "vault — источник истины: перезапись запрещена")
        let saved = try String(contentsOf: tempDir.appendingPathComponent("A/заметка.md"),
                               encoding: .utf8)
        XCTAssertEqual(saved, "первая")
    }
}
