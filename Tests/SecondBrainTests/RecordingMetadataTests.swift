// RecordingMetadataTests.swift — sidecar-метаданные записи: round-trip,
// снисходительные миграции (паттерн MigrationTests из MA), битые файлы.

import XCTest
@testable import SecondBrain

final class RecordingMetadataTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String, name: String = "meta.json") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    func testRoundTrip() throws {
        let metadata = RecordingMetadata(
            date: Date(timeIntervalSince1970: 1_752_300_000),
            duration: 125.5,
            source: .both,
            files: ["2026-07-12 10-30.m4a", "2026-07-12 10-30 (система).m4a"])
        let url = RecordingMetadataStore.sidecarURL(base: "2026-07-12 10-30", in: tempDir)
        try RecordingMetadataStore.save(metadata, to: url)
        let loaded = try RecordingMetadataStore.load(from: url)
        XCTAssertEqual(loaded, metadata)
        XCTAssertEqual(url.lastPathComponent, "2026-07-12 10-30.json")
    }

    func testMigrationFromMinimalJSON() throws {
        // Старый/чужой JSON без большинства полей обязан загрузиться с дефолтами.
        let url = try write(#"{"duration": 5}"#)
        let loaded = try RecordingMetadataStore.load(from: url)
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.duration, 5)
        XCTAssertEqual(loaded.date, .distantPast)
        XCTAssertEqual(loaded.source, .microphone)
        XCTAssertEqual(loaded.files, [])
    }

    func testUnknownSourceFallsBackToMicrophone() throws {
        // Файл из будущей версии с неизвестным режимом не роняет загрузку.
        let url = try write(#"{"source": "telepathy", "duration": 1}"#)
        let loaded = try RecordingMetadataStore.load(from: url)
        XCTAssertEqual(loaded.source, .microphone)
    }

    func testCorruptJSONThrows() throws {
        let url = try write("{ это не json")
        XCTAssertThrowsError(try RecordingMetadataStore.load(from: url))
    }
}
