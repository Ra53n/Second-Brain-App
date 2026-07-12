// RecordingSessionTests.swift — FSM сессии записи через мок-рекордеры:
// таблица переходов (по паттерну FSMTests из MA), длительность без пауз
// (инжектированные часы), файлы дорожек, sidecar на stop, подчистка при
// сбое старта, разрешение коллизий имён. Плюс тесты AudioLevelMeter.

import AVFoundation
import XCTest
@testable import SecondBrain

/// Мок дорожки: фиксирует вызовы, вместо звука «пишет» файл-заглушку.
private final class MockTrackRecorder: AudioTrackRecorder {
    var levelHandler: ((Float) -> Void)?
    private(set) var startURL: URL?
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    var failOnStart = false

    func start(to url: URL) throws {
        if failOnStart { throw AudioRecordingError.noInputDevice }
        startURL = url
        FileManager.default.createFile(atPath: url.path, contents: Data("caf".utf8))
    }

    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }

    func stop() throws -> URL {
        stopCount += 1
        guard let url = startURL else {
            throw AudioRecordingError.fileWriteFailed("не стартовал")
        }
        return url
    }
}

@MainActor
final class RecordingSessionTests: XCTestCase {
    var tempDir: URL!
    private var mic: MockTrackRecorder!
    private var system: MockTrackRecorder!
    /// Инжектируемые монотонные часы.
    var now: TimeInterval = 0
    /// 2026-07-12, точное локальное время не важно — имя вычисляется форматтером.
    let fixedDate = Date(timeIntervalSince1970: 1_783_000_000)

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mic = MockTrackRecorder()
        system = MockTrackRecorder()
        now = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Сессия с моками; «перепаковка» — переименование .caf → .m4a.
    private func makeSession(source: RecordingSource) -> RecordingSession {
        RecordingSession(
            source: source,
            directory: tempDir,
            micFactory: { self.mic },
            systemFactory: { self.system },
            convert: { url in
                let target = url.deletingPathExtension().appendingPathExtension("m4a")
                try FileManager.default.moveItem(at: url, to: target)
                return target
            },
            clock: { self.now },
            dateProvider: { self.fixedDate })
    }

    private var expectedBase: String { RecordingNamer.baseName(for: fixedDate) }

    // MARK: - Переходы

    func testStartMicrophoneOnly() throws {
        let session = makeSession(source: .microphone)
        try session.start()
        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(mic.startURL?.lastPathComponent, "\(expectedBase).caf")
        XCTAssertNil(system.startURL, "системная дорожка не должна стартовать")
    }

    func testStartSystemOnlyUsesPlainName() throws {
        let session = makeSession(source: .system)
        try session.start()
        // Единственная дорожка — имя без суффикса " (система)".
        XCTAssertEqual(system.startURL?.lastPathComponent, "\(expectedBase).caf")
        XCTAssertNil(mic.startURL)
    }

    func testStartBothWritesTwoTracks() throws {
        let session = makeSession(source: .both)
        try session.start()
        XCTAssertEqual(mic.startURL?.lastPathComponent, "\(expectedBase).caf")
        XCTAssertEqual(system.startURL?.lastPathComponent,
                       "\(expectedBase)\(RecordingNamer.systemTrackSuffix).caf")
    }

    /// Таблица недопустимых переходов: действие × состояние → invalidTransition.
    func testInvalidTransitions() async throws {
        // idle: всё, кроме start.
        var session = makeSession(source: .microphone)
        assertInvalid(try session.pause(), action: "pause", state: .idle)
        assertInvalid(try session.resume(), action: "resume", state: .idle)
        await assertInvalidAsync(session, action: "stop", state: .idle)

        // recording: start и resume недопустимы.
        try session.start()
        assertInvalid(try session.start(), action: "start", state: .recording)
        assertInvalid(try session.resume(), action: "resume", state: .recording)

        // paused: start и pause недопустимы.
        try session.pause()
        assertInvalid(try session.start(), action: "start", state: .paused)
        assertInvalid(try session.pause(), action: "pause", state: .paused)

        // stopped: не допускается ничего.
        _ = try await session.stop()
        assertInvalid(try session.start(), action: "start", state: .stopped)
        assertInvalid(try session.pause(), action: "pause", state: .stopped)
        assertInvalid(try session.resume(), action: "resume", state: .stopped)
        await assertInvalidAsync(session, action: "stop", state: .stopped)

        // Новая сессия: stop из idle недопустим и mock не трогается.
        session = makeSession(source: .microphone)
        XCTAssertEqual(session.state, .idle)
    }

    private func assertInvalid(_ expression: @autoclosure () throws -> Void,
                               action: String, state: RecordingState,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? AudioRecordingError,
                           .invalidTransition(from: state, action: action),
                           file: file, line: line)
        }
    }

    private func assertInvalidAsync(_ session: RecordingSession,
                                    action: String, state: RecordingState,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await session.stop()
            XCTFail("stop из \(state.rawValue) должен бросать", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AudioRecordingError,
                           .invalidTransition(from: state, action: action),
                           file: file, line: line)
        }
    }

    // MARK: - Пауза и длительность

    func testPauseResumeForwardedToAllTracks() throws {
        let session = makeSession(source: .both)
        try session.start()
        try session.pause()
        try session.resume()
        XCTAssertEqual([mic.pauseCount, mic.resumeCount], [1, 1])
        XCTAssertEqual([system.pauseCount, system.resumeCount], [1, 1])
    }

    func testDurationExcludesPauses() async throws {
        let session = makeSession(source: .microphone)
        now = 100
        try session.start()

        now = 110 // 10 с записи
        XCTAssertEqual(session.duration, 10, accuracy: 0.001)
        try session.pause()

        now = 130 // 20 с паузы — длительность не растёт
        XCTAssertEqual(session.duration, 10, accuracy: 0.001)
        try session.resume()

        now = 135 // ещё 5 с записи
        let result = try await session.stop()
        XCTAssertEqual(result.metadata.duration, 15, accuracy: 0.001)
    }

    // MARK: - Остановка: конвертация и sidecar

    func testStopConvertsTracksAndWritesSidecar() async throws {
        let session = makeSession(source: .both)
        try session.start()
        now = 60
        let result = try await session.stop()

        XCTAssertEqual(session.state, .stopped)
        // Обе дорожки перепакованы в .m4a, .caf не осталось.
        XCTAssertEqual(result.audioFiles.map(\.lastPathComponent),
                       ["\(expectedBase).m4a",
                        "\(expectedBase)\(RecordingNamer.systemTrackSuffix).m4a"])
        for url in result.audioFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasSuffix(".caf") }
        XCTAssertEqual(leftovers, [])

        // Sidecar читается и содержит правду о записи.
        let metadata = try RecordingMetadataStore.load(from: result.sidecarURL)
        XCTAssertEqual(result.sidecarURL.lastPathComponent, "\(expectedBase).json")
        XCTAssertEqual(metadata.source, .both)
        XCTAssertEqual(metadata.duration, 60, accuracy: 0.001)
        XCTAssertEqual(metadata.files,
                       ["\(expectedBase).m4a",
                        "\(expectedBase)\(RecordingNamer.systemTrackSuffix).m4a"])
        // Дата сериализуется в ISO8601 с секундной точностью.
        XCTAssertEqual(metadata.date.timeIntervalSince1970,
                       fixedDate.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Сбои и коллизии

    func testStartFailureStopsStartedTracksAndCleansFiles() throws {
        system.failOnStart = true
        let session = makeSession(source: .both)
        XCTAssertThrowsError(try session.start()) { error in
            XCTAssertEqual(error as? AudioRecordingError, .noInputDevice)
        }
        // Микрофонная дорожка успела стартовать — её погасили, огрызок удалили.
        XCTAssertEqual(mic.stopCount, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files, [])
        // Сессия осталась в idle — можно поменять источник и стартовать снова.
        XCTAssertEqual(session.state, .idle)
    }

    func testNameCollisionGetsNumericSuffix() throws {
        // Запись с этим именем уже существует (например, прошлая в ту же минуту).
        let existing = tempDir.appendingPathComponent("\(expectedBase).m4a")
        FileManager.default.createFile(atPath: existing.path, contents: Data())

        let session = makeSession(source: .microphone)
        try session.start()
        XCTAssertEqual(mic.startURL?.lastPathComponent, "\(expectedBase) (2).caf")
    }
}

// MARK: - AudioLevelMeter

final class AudioLevelMeterTests: XCTestCase {
    private func buffer(filledWith value: Float, frames: AVAudioFrameCount = 480) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let pointer = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { pointer[i] = value }
        return buffer
    }

    func testSilenceIsZero() {
        XCTAssertEqual(AudioLevelMeter.level(from: buffer(filledWith: 0)), 0)
    }

    func testFullScaleIsOne() {
        XCTAssertEqual(AudioLevelMeter.level(from: buffer(filledWith: 1)), 1, accuracy: 0.01)
    }

    func testQuietSignalIsBetween() {
        // −40 dBFS (амплитуда 0.01) → (−40 + 60) / 60 ≈ 0.33.
        let level = AudioLevelMeter.level(from: buffer(filledWith: 0.01))
        XCTAssertEqual(level, 1.0 / 3.0, accuracy: 0.02)
    }
}
