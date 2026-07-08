// AudioChunker.swift — разбиение длинного аудио на части под лимит провайдера.
//
// У OpenAI Whisper лимит 25 МБ на файл — длинную запись встречи режем по
// длительности и склеиваем транскрипты частей (см. OpenAIProvider.transcribe).
//
// planChunks — чистая логика (границы по длительности), тестируется без файлов.
// exportChunks — реальная нарезка через AVFoundation (AVAssetExportSession),
// проверяется только вручную (нужен настоящий аудиофайл и время на экспорт).

import Foundation
import AVFoundation

/// Один отрезок исходного аудио: [start, end) в секундах.
struct AudioChunkPlan: Equatable {
    let start: TimeInterval
    let end: TimeInterval
}

enum AudioChunker {

    /// Делит `duration` на отрезки не длиннее `maxChunkDuration`; последний
    /// может быть короче. Некорректный вход (<= 0) — пустой план (единственный
    /// отрезок — вся запись — обрабатывается вызывающим отдельно: план из
    /// одного элемента, когда запись уже укладывается в лимит).
    static func planChunks(duration: TimeInterval, maxChunkDuration: TimeInterval) -> [AudioChunkPlan] {
        guard duration > 0, maxChunkDuration > 0 else { return [] }
        var chunks: [AudioChunkPlan] = []
        var start: TimeInterval = 0
        while start < duration {
            let end = min(start + maxChunkDuration, duration)
            chunks.append(AudioChunkPlan(start: start, end: end))
            start = end
        }
        return chunks
    }

    /// Экспортирует каждый отрезок плана в отдельный m4a-файл во временную
    /// директорию. Реальный ввод-вывод — не покрыт юнит-тестами (нужен файл).
    static func exportChunks(of audioURL: URL, plan: [AudioChunkPlan]) async throws -> [URL] {
        let asset = AVURLAsset(url: audioURL)
        var results: [URL] = []
        for (index, chunk) in plan.enumerated() {
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw LLMError.badStatus(code: -1, message: "не удалось создать сессию экспорта для отрезка \(index)")
            }
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk-\(UUID().uuidString)-\(index).m4a")
            export.outputURL = outputURL
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(
                start: CMTime(seconds: chunk.start, preferredTimescale: 600),
                end: CMTime(seconds: chunk.end, preferredTimescale: 600)
            )
            await export.export()
            if let error = export.error { throw error }
            results.append(outputURL)
        }
        return results
    }
}
