// MicrophoneRecorder.swift — запись с микрофона через AVAudioEngine.
//
// Поток данных: inputNode → tap (PCM float32) → AVAudioFile (AAC в CAF).
// Пишем сразу сжатый AAC, без промежуточного WAV (минута WAV ~10 МБ):
// AVAudioFile сам конвертирует PCM-буферы в формат файла при записи.
// Пауза — атомарный флаг: tap продолжает работать, буферы не пишутся.
//
// Разрешение на микрофон запрашивает MeetingsViewModel ДО старта; без
// разрешения движок стартует, но отдаёт тишину — поэтому проверка снаружи.

import AVFoundation

final class MicrophoneRecorder: AudioTrackRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileURL: URL?

    // Флаг паузы пишется с главного потока, читается с аудио-потока — под локом.
    private let pauseLock = NSLock()
    private var _paused = false
    private var paused: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return _paused }
        set { pauseLock.lock(); _paused = newValue; pauseLock.unlock() }
    }

    var levelHandler: ((Float) -> Void)?

    func start(to url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecordingError.noInputDevice
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let audioFile: AVAudioFile
        do {
            // processingFormat файла обязан совпадать с форматом буферов tap'а —
            // задаём float32 и ту же interleaved-раскладку явно.
            audioFile = try AVAudioFile(forWriting: url,
                                        settings: settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: format.isInterleaved)
        } catch {
            throw AudioRecordingError.fileWriteFailed(error.localizedDescription)
        }
        file = audioFile
        fileURL = url

        // Файл захвачен замыканием сильно: даже если stop() занулит self.file,
        // «догоняющий» колбэк не обратится к освобождённому объекту.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.levelHandler?(AudioLevelMeter.level(from: buffer))
            guard !self.paused else { return }
            // Одиночный сбой записи буфера не валит запись — файл выйдет короче.
            try? audioFile.write(from: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw AudioRecordingError.fileWriteFailed(error.localizedDescription)
        }
    }

    func pause() { paused = true }
    func resume() { paused = false }

    func stop() throws -> URL {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // деинициализация AVAudioFile закрывает файл (flush заголовков)
        guard let url = fileURL else {
            throw AudioRecordingError.fileWriteFailed("запись не была начата")
        }
        return url
    }
}
