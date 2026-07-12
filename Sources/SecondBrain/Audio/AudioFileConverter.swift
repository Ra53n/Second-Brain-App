// AudioFileConverter.swift — перепаковка записи CAF(AAC) → .m4a и
// восстановление после краша.
//
// Почему двухступенчато: контейнер .m4a финализируется moov-атомом только при
// закрытии — после kill -9 файл нечитаем. CAF валиден на любом префиксе,
// поэтому дорожки пишутся в CAF, а при штатной остановке перепаковываются в
// .m4a без перекодирования (passthrough; fallback — перекодирование AppleM4A,
// если passthrough не справился с парой контейнер/кодек).
//
// Оставшийся после краша (или неудачной перепаковки) .caf подхватывает
// recoverOrphans(): перепаковывает, восстанавливает sidecar из имени файла
// и длительности самой записи. Если и это не удалось — .caf остаётся в списке
// записей как есть: он читаем и играет в AVPlayer.

import AVFoundation

enum AudioFileConverter {
    /// Перепаковывает CAF(AAC) в .m4a рядом; исходник удаляется при успехе.
    static func remuxToM4A(_ sourceURL: URL) async throws -> URL {
        let targetURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")
        do {
            try await export(sourceURL, to: targetURL, preset: AVAssetExportPresetPassthrough)
        } catch {
            // Passthrough капризен к контейнерам — пробуем честное перекодирование.
            try await export(sourceURL, to: targetURL, preset: AVAssetExportPresetAppleM4A)
        }
        try? FileManager.default.removeItem(at: sourceURL)
        return targetURL
    }

    /// Восстановление после краша: все осиротевшие .caf в папке перепаковываются
    /// в .m4a, для записей без sidecar'а он восстанавливается (дата — из имени,
    /// длительность — из самого файла; паузы, увы, уже не восстановить).
    /// Возвращает список восстановленных .m4a. Неудачи не бросают — .caf остаётся.
    static func recoverOrphans(in directory: URL) async -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }

        var recovered: [URL] = []
        for caf in items where caf.pathExtension.lowercased() == "caf" {
            guard let m4a = try? await remuxToM4A(caf) else { continue }
            recovered.append(m4a)
            restoreSidecarIfMissing(for: m4a, in: directory)
        }
        return recovered
    }

    /// Дописывает sidecar восстановленной записи (или добавляет файл в существующий).
    private static func restoreSidecarIfMissing(for audioURL: URL, in directory: URL) {
        let stem = audioURL.deletingPathExtension().lastPathComponent
        let isSystemTrack = stem.hasSuffix(RecordingNamer.systemTrackSuffix)
        let base = isSystemTrack
            ? String(stem.dropLast(RecordingNamer.systemTrackSuffix.count))
            : stem
        let sidecarURL = RecordingMetadataStore.sidecarURL(base: base, in: directory)
        let fileName = audioURL.lastPathComponent
        let duration = audioDuration(of: audioURL)

        if var metadata = try? RecordingMetadataStore.load(from: sidecarURL) {
            // Sidecar уже есть (краш случился между перепаковками дорожек) —
            // дописываем дорожку и уточняем длительность.
            guard !metadata.files.contains(fileName) else { return }
            metadata.files.append(fileName)
            metadata.duration = max(metadata.duration, duration)
            // Порядок обработки дорожек не гарантирован: докатившаяся вторая
            // дорожка другого вида поднимает режим до .both в обе стороны.
            if isSystemTrack, metadata.source == .microphone { metadata.source = .both }
            if !isSystemTrack, metadata.source == .system { metadata.source = .both }
            try? RecordingMetadataStore.save(metadata, to: sidecarURL)
        } else {
            let metadata = RecordingMetadata(
                date: RecordingNamer.date(fromBaseName: base) ?? .distantPast,
                duration: duration,
                source: isSystemTrack ? .system : .microphone,
                files: [fileName])
            try? RecordingMetadataStore.save(metadata, to: sidecarURL)
        }
    }

    /// Длительность аудиофайла, сек (0 — если файл не читается).
    static func audioDuration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func export(_ source: URL, to target: URL, preset: String) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AudioRecordingError.conversionFailed("экспорт-сессия недоступна (\(preset))")
        }
        try? FileManager.default.removeItem(at: target)
        if #available(macOS 15.0, *) {
            do {
                try await session.export(to: target, as: .m4a)
            } catch {
                throw AudioRecordingError.conversionFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = target
            session.outputFileType = .m4a
            await session.export()
            guard session.status == .completed else {
                throw AudioRecordingError.conversionFailed(
                    session.error?.localizedDescription ?? "статус \(session.status.rawValue)")
            }
        }
    }
}
