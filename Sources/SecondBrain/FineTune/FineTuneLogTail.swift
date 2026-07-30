// FineTuneLogTail.swift — дочитывание растущего train.log от сохранённого смещения.
//
// mlx-lm дописывает лог раз в ~11 с — секундного опроса хватает, DispatchSource
// тут только усложнил бы (таймер заводит вызывающий, не этот тип).

import Foundation

/// @unchecked Sendable: ViewModel гарантирует не более одного вызова readNew()
/// одновременно (guard в tick()), поэтому перенос на фоновую очередь безопасен.
final class FineTuneLogTail: @unchecked Sendable {
    private let url: URL
    private var offset: UInt64 = 0

    init(url: URL) {
        self.url = url
    }

    /// Хвост с прошлого вызова, "" если нового нет. Смещение больше размера
    /// файла — `start` затёр лог новым прогоном — сбрасывается на начало.
    func readNew() -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if offset > size { offset = 0 }
        guard offset < size else { return "" }
        guard (try? handle.seek(toOffset: offset)) != nil else { return "" }
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func reset() {
        offset = 0
    }
}
