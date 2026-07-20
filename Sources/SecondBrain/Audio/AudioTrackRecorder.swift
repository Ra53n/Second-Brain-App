// AudioTrackRecorder.swift — протокол одной дорожки записи + измерение уровня.
//
// RecordingSession работает с дорожками только через этот протокол — в тестах
// подставляются моки; реальные реализации: MicrophoneRecorder (AVAudioEngine)
// и SystemAudioRecorder (Core Audio process tap).
//
// Контракт по контейнеру: дорожка пишется как AAC в CAF-контейнер. CAF валиден
// на любом префиксе (заголовок допускает «размер данных неизвестен»), поэтому
// после kill -9 читаемо всё, что успело попасть на диск. Контейнер же .m4a
// финализируется moov-атомом только при закрытии — недописанный файл нечитаем.
// При штатной остановке сессия перепаковывает CAF → .m4a (AudioFileConverter).

import AVFoundation

/// Одна дорожка записи (микрофон или системный звук).
protocol AudioTrackRecorder: AnyObject {
    /// Колбэк уровня сигнала 0…1 для индикатора; вызывается с аудио-потока.
    var levelHandler: ((Float) -> Void)? { get set }
    /// Начать запись в файл (расширение определяет контейнер; сессия передаёт .caf).
    func start(to url: URL) throws
    /// Приостановить: аудио-поток остаётся живым, буферы просто не пишутся —
    /// перезапуск движков/тапов капризнее и дольше, чем пропуск буферов.
    func pause()
    func resume()
    /// Остановить и закрыть файл; возвращает URL записанного файла.
    func stop() throws -> URL
    /// Прерывалась ли дорожка во время записи по внешней причине (напр.,
    /// системный звук потерял устройство вывода и пересборка не удалась) —
    /// чтобы предупредить пользователя. Дефолт — false.
    var wasInterrupted: Bool { get }
}

extension AudioTrackRecorder {
    var wasInterrupted: Bool { false }
}

/// RMS-уровень сигнала для индикатора в UI.
enum AudioLevelMeter {
    /// Уровень 0…1: −60 dBFS и тише → 0, полная шкала (0 dBFS) → 1.
    static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        if buffer.format.isInterleaved {
            // Interleaved: все сэмплы лежат подряд в data[0].
            let p = data[0]
            let count = frames * channels
            for i in 0..<count { sum += p[i] * p[i] }
        } else {
            for ch in 0..<channels {
                let p = data[ch]
                for i in 0..<frames { sum += p[i] * p[i] }
            }
        }
        let rms = sqrt(sum / Float(frames * channels))
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 60) / 60))
    }
}
