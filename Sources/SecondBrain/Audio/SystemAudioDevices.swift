// SystemAudioDevices.swift — перечисление устройств вывода для выбора источника
// системного звука и резолвер «какое устройство писать сейчас».
//
// Проблема, ради которой это появилось: агрегат-девайс тапа привязан к
// устройству вывода. При смене вывода (пользователь вывел звук на наушники)
// системный захват молча обрывался. Теперь пользователь может (а) явно выбрать
// устройство и (б) в режиме «Авто» захват следует за системным выводом
// (SystemAudioRecorder слушает смену и пересобирает агрегат).
//
// Core Audio-перечисление (availableOutputs/defaultOutputUID/deviceID) — железо,
// юнит-тестами не покрывается. Чистая логика выбора вынесена в
// SystemAudioDeviceResolver и тестируется отдельно.

import AudioToolbox
import CoreAudio
import Foundation

/// Устройство вывода для пикера «откуда писать системный звук».
struct AudioOutputDevice: Identifiable, Equatable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Чистая логика выбора устройства — тестируется без Core Audio.
enum SystemAudioDeviceResolver {
    /// nil preferred = «Авто» (следовать за системным выводом по умолчанию).
    static func isAuto(_ preferred: String?) -> Bool { preferred == nil }

    /// Какое устройство реально захватывать: выбранное пользователем, если оно
    /// сейчас доступно; иначе — системное по умолчанию (режим «Авто» либо
    /// выбранное устройство отключили).
    static func effectiveUID(preferred: String?,
                             availableUIDs: [String],
                             defaultUID: String?) -> String? {
        if let preferred, availableUIDs.contains(preferred) { return preferred }
        return defaultUID
    }

    /// Сменилось ли устройство, которое нужно захватывать, при переходе системы
    /// на `newDefaultUID`. Для «Авто» — сравниваем с текущим захватываемым; для
    /// явного выбора устройство не меняется, пока оно доступно.
    static func shouldRebuild(preferred: String?,
                              capturing currentUID: String?,
                              availableUIDs: [String],
                              newDefaultUID: String?) -> Bool {
        let target = effectiveUID(preferred: preferred,
                                  availableUIDs: availableUIDs,
                                  defaultUID: newDefaultUID)
        return target != currentUID
    }
}

/// Core Audio-перечисление устройств вывода (не тестируется — железо).
@available(macOS 14.4, *)
enum SystemAudioDevices {

    /// Все устройства с выходными каналами: (uid, name), в порядке Core Audio.
    static func availableOutputs() -> [AudioOutputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasOutputChannels(id), let uid = uid(of: id) else { return nil }
            return AudioOutputDevice(uid: uid, name: name(of: id) ?? uid)
        }
    }

    /// UID системного устройства вывода по умолчанию.
    static func defaultOutputUID() -> String? {
        guard let id = defaultOutputDeviceID() else { return nil }
        return uid(of: id)
    }

    /// AudioDeviceID по UID (для создания агрегата / слушателя).
    static func deviceID(forUID target: String) -> AudioDeviceID? {
        allDeviceIDs().first { uid(of: $0) == target }
    }

    // MARK: - Внутренности

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    /// Есть ли у устройства выходные каналы (иначе это чистый вход — не вывод).
    private static func hasOutputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }
        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }
        let abl = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return abl.contains { $0.mNumberChannels > 0 }
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func name(of id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioObjectPropertyName)
    }

    /// CFString-свойство устройства; из C API приходит с +1 retain.
    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
