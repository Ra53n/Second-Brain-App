// RecordingTypes.swift — общие типы подсистемы записи звука.
//
// Здесь живут:
//  - RecordingSource: что пишем (микрофон / системный звук / оба);
//  - RecordingState: состояния FSM сессии записи (idle → recording ⇄ paused → stopped);
//  - AudioRecordingError: все ошибки подсистемы с сообщениями для UI.
//
// Решение по комбинированному режиму (.both): пишем ДВЕ дорожки в два файла
// (микрофон и система отдельно), без реалтайм-микса. Микс двух асинхронных
// источников (разные clock-домены) требует ring-буферов и drift-компенсации;
// два файла проще и надёжнее, а транскрипции (задача 11) раздельные дорожки
// даже удобнее — диктора и собеседников не надо разделять по громкости.
// Решение зафиксировано в docs/ARCHITECTURE.md.

import Foundation

/// Источник записи, выбирается пользователем в UI.
enum RecordingSource: String, Codable, CaseIterable, Identifiable {
    case microphone // только микрофон (встреча в переговорке)
    case system     // только системный звук (вебинар, где сам молчишь)
    case both       // микрофон + система, две дорожки (Zoom/Meet)

    var id: String { rawValue }

    /// Название режима для UI.
    var title: String {
        switch self {
        case .microphone: return "Микрофон"
        case .system: return "Система"
        case .both: return "Оба"
        }
    }

    var needsMicrophone: Bool { self != .system }
    var needsSystemAudio: Bool { self != .microphone }
}

/// Состояния сессии записи. Переходы охраняются в RecordingSession
/// (guarded transitions, как в FSM Manager Assistant):
/// idle → recording ⇄ paused → stopped; всё остальное — ошибка.
enum RecordingState: String, Codable {
    case idle
    case recording
    case paused
    case stopped
}

/// Ошибки подсистемы записи; сообщения пригодны для показа в UI.
enum AudioRecordingError: LocalizedError, Equatable {
    case invalidTransition(from: RecordingState, action: String)
    case noVault                                      // некуда писать: vault не открыт
    case microphonePermissionDenied
    case noInputDevice
    case systemAudioUnsupported                       // macOS < 14.4
    case coreAudio(operation: String, status: Int32)  // ошибка Core Audio (OSStatus)
    case fileWriteFailed(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidTransition(from, action):
            return "Недопустимое действие «\(action)» в состоянии \(from.rawValue)."
        case .noVault:
            return "Откройте vault: записи сохраняются в <vault>/Meetings/_recordings/."
        case .microphonePermissionDenied:
            return "Нет доступа к микрофону. Разрешите в Системных настройках → Конфиденциальность → Микрофон."
        case .noInputDevice:
            return "Не найдено входное аудиоустройство (микрофон)."
        case .systemAudioUnsupported:
            return "Запись системного звука требует macOS 14.4+. Запись с микрофона доступна."
        case let .coreAudio(operation, status):
            return "Ошибка Core Audio на шаге «\(operation)» (код \(status)). "
                + "Проверьте разрешение: Системные настройки → Конфиденциальность → Запись экрана и системного звука."
        case let .fileWriteFailed(detail):
            return "Не удалось записать аудиофайл: \(detail)"
        case let .conversionFailed(detail):
            return "Не удалось перепаковать запись в .m4a: \(detail)"
        }
    }
}
