// MeetingStoreTests.swift — персистентность контекстов встреч: round-trip,
// миграция минимального JSON, карантин битого файла, normalize на старте
// (зависшие running → paused) — паттерн MigrationTests из MA.

import XCTest
@testable import SecondBrain

@MainActor
final class MeetingStoreTests: XCTestCase {
    var tempDir: URL!
    var fileURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("meetings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTrip() {
        var context = MeetingContext(recordingBase: "2026-07-12 10-30",
                                     audioFiles: ["2026-07-12 10-30.m4a"],
                                     recordedAt: Date(timeIntervalSince1970: 1_783_000_000),
                                     duration: 60,
                                     presetTitle: "1:1 с Петей")
        context.state = .transcribed
        context.transcripts = [TrackTranscript(
            fileName: "2026-07-12 10-30.m4a",
            transcript: Transcript(fullText: "текст", segments: [], language: "ru"))]
        MeetingPersistence.save([context], to: fileURL)
        let loaded = MeetingPersistence.load(from: fileURL)
        XCTAssertEqual(loaded, [context])
    }

    func testMigrationFromMinimalJSON() throws {
        // Контекст из «старой версии»: только пара полей — обязан загрузиться.
        let json = #"[{"recordingBase": "2026-01-01 09-00", "state": "transcribing"}]"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = MeetingPersistence.load(from: fileURL)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].recordingBase, "2026-01-01 09-00")
        XCTAssertEqual(loaded[0].state, .transcribing)
        XCTAssertEqual(loaded[0].status, .paused, "нет статуса → paused (возобновляемо)")
        XCTAssertEqual(loaded[0].stepRetries, 0)
        XCTAssertEqual(loaded[0].transcripts, [])
    }

    func testUnknownStateAndStatusFallBack() throws {
        let json = #"[{"recordingBase": "b", "state": "квантовый", "status": "неведомый"}]"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = MeetingPersistence.load(from: fileURL)
        XCTAssertEqual(loaded[0].state, .recorded, "неизвестный этап → с начала (идемпотентно)")
        XCTAssertEqual(loaded[0].status, .paused)
    }

    func testCorruptFileQuarantined() throws {
        try Data("{ не json".utf8).write(to: fileURL)
        let loaded = MeetingPersistence.load(from: fileURL)
        XCTAssertEqual(loaded, [])
        let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "битый файл уезжает в карантин, не теряется")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testNormalizeRunningToPausedOnLoad() {
        var running = MeetingContext(recordingBase: "a", audioFiles: [],
                                     recordedAt: .now, duration: 0)
        running.state = .transcribing
        running.status = .running
        var finished = MeetingContext(recordingBase: "b", audioFiles: [],
                                      recordedAt: .now, duration: 0)
        finished.state = .done
        finished.status = .finished
        MeetingPersistence.save([running, finished], to: fileURL)

        let store = MeetingStore(fileURL: fileURL)
        XCTAssertEqual(store.context(forRecordingBase: "a")?.status, .paused,
                       "зависший running после рестарта → paused")
        XCTAssertEqual(store.context(forRecordingBase: "b")?.status, .finished,
                       "завершённые не трогаем")
        // Нормализация сразу зафиксирована на диске.
        let onDisk = MeetingPersistence.load(from: fileURL)
        XCTAssertEqual(onDisk.first { $0.recordingBase == "a" }?.status, .paused)
    }

    func testMutatePersistsImmediately() {
        let context = MeetingContext(recordingBase: "a", audioFiles: [],
                                     recordedAt: .now, duration: 0)
        let store = MeetingStore(fileURL: fileURL)
        store.upsert(context)
        store.mutate(id: context.id) { $0.summary = "готово" }
        // persistNow — без ожидания debounce.
        let onDisk = MeetingPersistence.load(from: fileURL)
        XCTAssertEqual(onDisk.first?.summary, "готово")
    }
}
