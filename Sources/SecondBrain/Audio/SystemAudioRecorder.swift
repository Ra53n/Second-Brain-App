// SystemAudioRecorder.swift — захват всего системного звука через Core Audio
// process tap (WWDC24 «Capture system audio with Core Audio taps», macOS 14.4+).
//
// Схема:
//  1. CATapDescription(stereoGlobalTapButExcludeProcesses: []) — тап на весь вывод;
//  2. AudioHardwareCreateProcessTap → tap-объект, у него читаем формат потока;
//  3. приватный агрегат-девайс: default-output в SubDeviceList + тап в TapList
//     (drift-компенсация включена, TapAutoStart);
//  4. IOProc на агрегате: входные буферы = звук тапа → AVAudioFile (AAC в CAF).
//
// Разрешение: первый старт вызывает TCC-промпт «запись системного звука»
// (ключ NSAudioCaptureUsageDescription в Info.plist — добавлен в run.sh).
// При отладке через `swift run` разрешение выдаётся терминалу, у собранного
// SecondBrain.app — своё; проверять надо оба сценария. Надёжного API «узнать
// статус разрешения без промпта» нет — сбои всплывают на старте записи.
//
// Любой сбой Core Audio → AudioRecordingError.coreAudio с кодом и шагом;
// UI показывает понятное сообщение, микрофонный режим продолжает работать
// (graceful fallback из задачи 06).

import AVFoundation
import AudioToolbox

@available(macOS 14.4, *)
final class SystemAudioRecorder: AudioTrackRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var fileURL: URL?
    /// Очередь IOProc-колбэков; на ней же пишем файл.
    private let ioQueue = DispatchQueue(label: "com.local.second-brain.system-tap")

    // Флаг паузы пишется с главного потока, читается с ioQueue — под локом.
    private let pauseLock = NSLock()
    private var _paused = false
    private var paused: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return _paused }
        set { pauseLock.lock(); _paused = newValue; pauseLock.unlock() }
    }

    var levelHandler: ((Float) -> Void)?

    func start(to url: URL) throws {
        // 1. Тап на весь системный вывод (пустой список исключений).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "SecondBrain System Audio Tap"
        description.isPrivate = true        // не светится в Audio MIDI Setup
        description.muteBehavior = .unmuted // пользователь продолжает слышать звук
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "создание process tap")
        tapID = tap

        do {
            // 2. Формат тапа (обычно stereo float32 с sample rate текущего вывода).
            var asbd = try tapStreamDescription()
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw AudioRecordingError.coreAudio(operation: "формат тапа", status: -1)
            }

            // 3. Файл AAC-в-CAF; processingFormat совпадает с форматом тапа.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forWriting: url,
                                            settings: settings,
                                            commonFormat: .pcmFormatFloat32,
                                            interleaved: format.isInterleaved)
            } catch {
                throw AudioRecordingError.fileWriteFailed(error.localizedDescription)
            }

            // 4. Приватный агрегат-девайс с тапом.
            aggregateID = try makeAggregateDevice(tapUUID: description.uuid)

            // 5. IOProc: входные данные агрегата — звук тапа.
            var procID: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
                [weak self] _, inInputData, _, _, _ in
                self?.handleInput(inInputData, format: format, file: audioFile)
            }
            try check(status, "создание IOProc")
            ioProcID = procID
            try check(AudioDeviceStart(aggregateID, procID), "старт агрегат-устройства")

            file = audioFile
            fileURL = url
        } catch {
            teardownCoreAudio()
            file = nil
            throw error
        }
    }

    func pause() { paused = true }
    func resume() { paused = false }

    func stop() throws -> URL {
        teardownCoreAudio()
        file = nil // закрывает файл
        guard let url = fileURL else {
            throw AudioRecordingError.fileWriteFailed("запись не была начата")
        }
        return url
    }

    // MARK: - Внутренности

    /// Колбэк IOProc (на ioQueue): оборачиваем AudioBufferList без копии и пишем.
    private func handleInput(_ list: UnsafePointer<AudioBufferList>,
                             format: AVAudioFormat,
                             file: AVAudioFile) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            bufferListNoCopy: UnsafeMutablePointer(mutating: list),
                                            deallocator: nil) else { return }
        levelHandler?(AudioLevelMeter.level(from: buffer))
        guard !paused else { return }
        // Одиночный сбой записи буфера не валит запись — файл выйдет короче.
        try? file.write(from: buffer)
    }

    /// Формат потока тапа.
    private func tapStreamDescription() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd),
                  "чтение формата тапа")
        return asbd
    }

    /// Приватный агрегат: устройство вывода по умолчанию + наш тап.
    private func makeAggregateDevice(tapUUID: UUID) throws -> AudioObjectID {
        let outputUID = try defaultOutputDeviceUID()
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SecondBrain System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString,
                 kAudioSubTapDriftCompensationKey: true]
            ]
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate),
                  "создание агрегат-устройства")
        return aggregate
    }

    /// UID системного устройства вывода по умолчанию.
    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size, &deviceID),
                  "поиск устройства вывода")
        address.mSelector = kAudioDevicePropertyDeviceUID
        // CFString из C API приходит с +1 retain — принимаем через Unmanaged.
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &uidSize, &uid),
                  "чтение UID устройства вывода")
        guard let uid else {
            throw AudioRecordingError.coreAudio(operation: "чтение UID устройства вывода", status: -1)
        }
        return uid.takeRetainedValue() as String
    }

    /// Гасим и уничтожаем Core Audio-объекты в обратном порядке создания.
    /// Ошибки на teardown игнорируются: часть объектов могла не создаться.
    private func teardownCoreAudio() {
        if let procID = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioRecordingError.coreAudio(operation: operation, status: status)
        }
    }
}
