// SystemAudioRecorder.swift — захват всего системного звука через Core Audio
// process tap (WWDC24 «Capture system audio with Core Audio taps», macOS 14.4+).
//
// Схема:
//  1. CATapDescription(stereoGlobalTapButExcludeProcesses: []) — тап на весь вывод;
//  2. AudioHardwareCreateProcessTap → tap-объект, у него читаем формат потока;
//  3. приватный агрегат-девайс: устройство вывода в SubDeviceList + тап в TapList
//     (drift-компенсация включена, TapAutoStart);
//  4. IOProc на агрегате: входные буферы = звук тапа → AVAudioFile (AAC в CAF).
//
// Устройство вывода и горячая пересборка: агрегат тактируется КОНКРЕТНЫМ
// устройством вывода. Раньше оно фиксировалось на старте — при смене вывода
// (пользователь вывел звук на наушники) тап молча замолкал и системная дорожка
// обрывалась. Теперь:
//  - можно явно выбрать устройство (preferredDeviceUID); nil — «Авто»;
//  - слушаем смену default output и на лету пересобираем агрегат/тап на новое
//    устройство, продолжая писать в тот же файл (с конвертацией формата, если
//    sample rate разошёлся);
//  - если пересборка не удалась — wasInterrupted=true (UI предупредит), но уже
//    записанное сохраняется, а микрофонная дорожка не страдает.
//
// Разрешение: первый старт вызывает TCC-промпт «запись системного звука»
// (ключ NSAudioCaptureUsageDescription в Info.plist — добавлен в run.sh).
//
// Любой сбой Core Audio на СТАРТЕ → AudioRecordingError.coreAudio с кодом и
// шагом; UI показывает понятное сообщение, микрофонный режим продолжает работать.

import AVFoundation
import AudioToolbox

@available(macOS 14.4, *)
final class SystemAudioRecorder: AudioTrackRecorder {
    /// Явно выбранное устройство вывода; nil — «Авто» (следовать за системным).
    private let preferredDeviceUID: String?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var fileURL: URL?
    /// Формат файла — фиксируется по первому тапу и не меняется при пересборке
    /// (буферы нового устройства при необходимости конвертируются к нему).
    private var fileFormat: AVAudioFormat?
    /// UID устройства, которое пишем прямо сейчас (для решения о пересборке).
    private var capturingUID: String?
    /// Конвертер формат-тапа → формат-файла (nil, если совпадают).
    private var converter: AVAudioConverter?
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// Очередь IOProc-колбэков (запись буферов).
    private let ioQueue = DispatchQueue(label: "com.local.second-brain.system-tap")
    /// Отдельная управляющая очередь: слушатель смены устройства, пересборка,
    /// start/stop. НЕ ioQueue — иначе AudioDeviceStop, вызванный из аудио-очереди,
    /// может дедлочить с останавливаемым IOProc-потоком.
    private let controlQueue = DispatchQueue(label: "com.local.second-brain.system-tap-control")
    /// Защищает file/fileFormat/converter — их пишет пересборка (controlQueue),
    /// читает handleInput (ioQueue).
    private let chainLock = NSLock()

    // Флаг паузы: пишется с главного потока, читается с ioQueue — под локом.
    private let pauseLock = NSLock()
    private var _paused = false
    private var paused: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return _paused }
        set { pauseLock.lock(); _paused = newValue; pauseLock.unlock() }
    }

    // Флаг прерывания: ставится на ioQueue (пересборка не удалась), читается снаружи.
    private let interruptLock = NSLock()
    private var _interrupted = false
    var wasInterrupted: Bool {
        interruptLock.lock(); defer { interruptLock.unlock() }; return _interrupted
    }

    var levelHandler: ((Float) -> Void)?

    init(preferredDeviceUID: String? = nil) {
        self.preferredDeviceUID = preferredDeviceUID
    }

    func start(to url: URL) throws {
        fileURL = url
        guard let target = resolveTargetDevice() else {
            throw AudioRecordingError.coreAudio(operation: "поиск устройства вывода", status: -1)
        }
        do {
            try controlQueue.sync { try buildChain(deviceUID: target) }
        } catch {
            controlQueue.sync { teardownChain() }
            setFile(nil)
            throw error
        }
        installDefaultOutputListener()
    }

    func pause() { paused = true }
    func resume() { paused = false }

    func stop() throws -> URL {
        removeDefaultOutputListener()
        controlQueue.sync { teardownChain() }
        setFile(nil) // закрывает файл (flush заголовков)
        guard let url = fileURL else {
            throw AudioRecordingError.fileWriteFailed("запись не была начата")
        }
        return url
    }

    // MARK: - Построение / разбор Core Audio-цепочки

    /// Создаёт tap + (при первом вызове) файл + агрегат на `deviceUID` + IOProc и
    /// запускает захват. Переиспользуется при горячей пересборке — файл не трогает.
    private func buildChain(deviceUID: String) throws {
        // 1. Тап на весь системный вывод (пустой список исключений).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "SecondBrain System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "создание process tap")
        tapID = tap

        // 2. Формат тапа (обычно stereo float32 с sample rate текущего вывода).
        var asbd = try tapStreamDescription()
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioRecordingError.coreAudio(operation: "формат тапа", status: -1)
        }

        // 3. Файл AAC-в-CAF — только при первом старте; формат фиксируется.
        //    file/fileFormat/converter пишутся под chainLock (читает handleInput).
        if currentFile() == nil {
            guard let url = fileURL else {
                throw AudioRecordingError.fileWriteFailed("нет пути записи")
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: tapFormat.sampleRate,
                AVNumberOfChannelsKey: tapFormat.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forWriting: url, settings: settings,
                                            commonFormat: .pcmFormatFloat32,
                                            interleaved: tapFormat.isInterleaved)
            } catch {
                throw AudioRecordingError.fileWriteFailed(error.localizedDescription)
            }
            chainLock.lock()
            file = audioFile
            fileFormat = tapFormat
            chainLock.unlock()
        }

        // 4. Конвертер, если формат нового устройства разошёлся с форматом файла
        //    (пересборка на устройство с другим sample rate).
        chainLock.lock()
        if let ff = fileFormat, tapFormat != ff {
            converter = AVAudioConverter(from: tapFormat, to: ff)
        } else {
            converter = nil
        }
        chainLock.unlock()

        // 5. Приватный агрегат на выбранном устройстве + тап.
        aggregateID = try makeAggregateDevice(tapUUID: description.uuid, outputUID: deviceUID)

        // 6. IOProc: входные данные агрегата — звук тапа.
        let capturedTapFormat = tapFormat
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleInput(inInputData, tapFormat: capturedTapFormat)
        }
        try check(status, "создание IOProc")
        ioProcID = procID
        try check(AudioDeviceStart(aggregateID, procID), "старт агрегат-устройства")
        capturingUID = deviceUID
    }

    /// Гасит Core Audio-объекты цепочки (tap+агрегат+IOProc), НЕ трогая файл —
    /// для пересборки и для stop().
    private func teardownChain() {
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
        chainLock.lock(); converter = nil; chainLock.unlock()
    }

    private func currentFile() -> AVAudioFile? {
        chainLock.lock(); defer { chainLock.unlock() }; return file
    }

    private func setFile(_ newFile: AVAudioFile?) {
        chainLock.lock(); file = newFile; chainLock.unlock()
    }

    // MARK: - Горячая смена устройства

    /// Слушатель смены системного устройства вывода — пересобирает цепочку.
    private func installDefaultOutputListener() {
        var address = defaultOutputAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputChange()
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
    }

    private func removeDefaultOutputListener() {
        guard let block = listenerBlock else { return }
        var address = defaultOutputAddress()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
        listenerBlock = nil
    }

    /// Реакция на смену вывода (на ioQueue — сериализовано с записью буферов).
    private func handleDefaultOutputChange() {
        let available = SystemAudioDevices.availableOutputs().map(\.uid)
        let newDefault = SystemAudioDevices.defaultOutputUID()
        guard SystemAudioDeviceResolver.shouldRebuild(
            preferred: preferredDeviceUID, capturing: capturingUID,
            availableUIDs: available, newDefaultUID: newDefault) else { return }
        guard let target = SystemAudioDeviceResolver.effectiveUID(
            preferred: preferredDeviceUID, availableUIDs: available,
            defaultUID: newDefault) else { markInterrupted(); return }

        teardownChain() // файл и его формат сохраняем
        do {
            try buildChain(deviceUID: target) // захват продолжается на новом устройстве
        } catch {
            markInterrupted()
        }
    }

    private func markInterrupted() {
        interruptLock.lock(); _interrupted = true; interruptLock.unlock()
    }

    // MARK: - Запись буферов

    /// Колбэк IOProc (на ioQueue): оборачиваем AudioBufferList без копии, при
    /// необходимости конвертируем к формату файла и пишем.
    private func handleInput(_ list: UnsafePointer<AudioBufferList>, tapFormat: AVAudioFormat) {
        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: UnsafeMutablePointer(mutating: list),
            deallocator: nil) else { return }
        levelHandler?(AudioLevelMeter.level(from: inBuffer))
        guard !paused else { return }
        // Снимок под локом: пересборка (controlQueue) могла сменить file/converter.
        chainLock.lock()
        let file = self.file
        let converter = self.converter
        let fileFormat = self.fileFormat
        chainLock.unlock()
        guard let file else { return }

        guard let converter, let fileFormat else {
            // Форматы совпадают — пишем напрямую.
            try? file.write(from: inBuffer)
            return
        }
        // Пересобрались на устройство с другим форматом — конвертируем.
        let ratio = fileFormat.sampleRate / tapFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        var supplied = false
        let input: AVAudioConverterInputBlock = { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuffer
        }
        converter.convert(to: outBuffer, error: &error, withInputFrom: input)
        if error == nil, outBuffer.frameLength > 0 {
            try? file.write(from: outBuffer)
        }
    }

    // MARK: - Core Audio helpers

    private func defaultOutputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Устройство, которое реально захватываем: выбранное, если доступно; иначе
    /// системное по умолчанию.
    private func resolveTargetDevice() -> String? {
        SystemAudioDeviceResolver.effectiveUID(
            preferred: preferredDeviceUID,
            availableUIDs: SystemAudioDevices.availableOutputs().map(\.uid),
            defaultUID: SystemAudioDevices.defaultOutputUID())
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

    /// Приватный агрегат: заданное устройство вывода + наш тап.
    private func makeAggregateDevice(tapUUID: UUID, outputUID: String) throws -> AudioObjectID {
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

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioRecordingError.coreAudio(operation: operation, status: status)
        }
    }
}
