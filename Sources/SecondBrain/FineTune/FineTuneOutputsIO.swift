// FineTuneOutputsIO.swift — чтение снятых baseline/tuned-каталогов (I/O рядом с
// чистым ядром FineTuneOutputsReader.swift).

import Foundation

/// Собирает Snapshot из каталога baseline/tuned — outputs.json (может отсутствовать)
/// и все NN-*.md рядом. Каталога нет → nil, без бросков.
enum FineTuneOutputsIO {
    static func readSnapshot(directory: URL) -> FineTuneOutputsReader.Snapshot? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }

        let outputsURL = directory.appendingPathComponent("outputs.json")
        let parsed = (try? Data(contentsOf: outputsURL)).flatMap(FineTuneOutputsReader.parseOutputs)
        let meta = parsed?.meta ?? FineTuneOutputsReader.Meta(provider: nil, model: nil, adapter: nil, temperature: nil)
        let texts = parsed?.texts ?? [:]

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let answers = entries
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> FineTuneOutputsReader.Answer? in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return FineTuneOutputsReader.parseAnswerFile(name: url.lastPathComponent, content: content)
            }
            .sorted { $0.index < $1.index }

        return FineTuneOutputsReader.Snapshot(meta: meta, answers: answers,
                                              textsOnly: answers.isEmpty ? texts : [:])
    }
}
