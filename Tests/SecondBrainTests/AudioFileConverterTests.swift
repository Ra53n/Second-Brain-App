// AudioFileConverterTests.swift — перепаковка CAF(AAC) → .m4a и восстановление
// осиротевших записей. Аудио-железо не нужно: исходный CAF синтезируется
// из синуса через AVAudioFile — тот же путь записи, что у реальных рекордеров.

import AVFoundation
import XCTest
@testable import SecondBrain

final class AudioFileConverterTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Пишет секунду синуса 440 Гц как AAC-в-CAF — как настоящий рекордер.
    @discardableResult
    private func makeCAF(named name: String, seconds: Double = 1.0) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let pointer = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            pointer[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
        }
        try file.write(from: buffer)
        return url
    }

    func testRemuxProducesReadableM4A() async throws {
        let caf = try makeCAF(named: "2026-07-12 10-30.caf")
        let m4a = try await AudioFileConverter.remuxToM4A(caf)

        XCTAssertEqual(m4a.lastPathComponent, "2026-07-12 10-30.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: caf.path),
                       "исходный .caf удаляется после успешной перепаковки")
        // Результат читается, длительность сохранилась (кодек не перекодировался,
        // но паддинг AAC-праймера допускаем — точность 0.1 с).
        XCTAssertEqual(AudioFileConverter.audioDuration(of: m4a), 1.0, accuracy: 0.1)
    }

    func testRecoverOrphansConvertsAndRestoresSidecar() async throws {
        // Ситуация после kill -9: две дорожки .caf, sidecar не записан.
        try makeCAF(named: "2026-07-12 10-30.caf")
        try makeCAF(named: "2026-07-12 10-30\(RecordingNamer.systemTrackSuffix).caf")

        let recovered = await AudioFileConverter.recoverOrphans(in: tempDir)
        XCTAssertEqual(recovered.count, 2)

        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
        XCTAssertEqual(files, ["2026-07-12 10-30 (система).m4a",
                               "2026-07-12 10-30.json",
                               "2026-07-12 10-30.m4a"])

        // Sidecar восстановлен: обе дорожки, режим .both, дата из имени.
        let sidecar = RecordingMetadataStore.sidecarURL(base: "2026-07-12 10-30", in: tempDir)
        let metadata = try RecordingMetadataStore.load(from: sidecar)
        XCTAssertEqual(Set(metadata.files),
                       ["2026-07-12 10-30.m4a", "2026-07-12 10-30 (система).m4a"])
        XCTAssertEqual(metadata.source, .both)
        XCTAssertEqual(metadata.date, RecordingNamer.date(fromBaseName: "2026-07-12 10-30"))
        XCTAssertEqual(metadata.duration, 1.0, accuracy: 0.1)
    }

    func testRecoverOrphansIgnoresForeignFiles() async {
        // Папка без .caf (и с посторонним файлом) — ничего не делаем.
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("заметка.md").path,
            contents: Data("не трогать".utf8))
        let recovered = await AudioFileConverter.recoverOrphans(in: tempDir)
        XCTAssertEqual(recovered, [])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("заметка.md").path))
    }
}
