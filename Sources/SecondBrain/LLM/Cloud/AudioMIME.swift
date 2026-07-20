// AudioMIME.swift — MIME-типы аудиоконтейнеров для облачных STT.
//
// Единый источник истины: раньше таблица «расширение → MIME» дублировалась в
// DeepgramProvider/OpenAIProvider/GeminiProvider. Неверный тип (захардкоженный
// audio/mpeg) заставлял бэкенды спотыкаться о несоответствие контейнера и
// заявленного типа — Deepgram на .caf под видом audio/mpeg отвечает
// «failed to process audio: corrupt or unsupported data».
//
// Внутренний контейнер записи — CAF (см. AudioTrackRecorder): облачные STT его
// напрямую не принимают, поэтому перед отправкой он перепаковывается в .m4a
// (MeetingPipeline через AudioFileConverter). isCloudSTTReady отделяет форматы,
// которые можно слать как есть, от тех, что требуют нормализации.

import Foundation

enum AudioMIME {
    /// MIME-тип по расширению файла. Неизвестное расширение → audio/mpeg
    /// (исторический дефолт; на практике не встречается — мы пишем .m4a/.caf).
    static func type(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":                 return "audio/wav"
        case "mp3":                 return "audio/mpeg"
        case "m4a", "mp4", "aac":   return "audio/mp4"
        case "flac":                return "audio/flac"
        case "ogg", "oga", "opus":  return "audio/ogg"
        case "webm":                return "audio/webm"
        case "caf":                 return "audio/x-caf"
        default:                    return "audio/mpeg"
        }
    }

    /// Можно ли отправить файл в облачный STT без перепаковки. Внутренний CAF —
    /// нельзя (облака его не парсят), его нормализуют в .m4a перед отправкой.
    static func isCloudSTTReady(_ url: URL) -> Bool {
        url.pathExtension.lowercased() != "caf"
    }
}
