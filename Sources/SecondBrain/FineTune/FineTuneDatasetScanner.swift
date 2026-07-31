// FineTuneDatasetScanner.swift — сканирование каталогов-датасетов finetune/ (I/O).
//
// Признак датасета — `<dir>/data/train.jsonl`; ищем в самом `finetune/` (workdir
// ".") и в подкаталогах глубины 1 (например "dictation"). Каталог отсутствует
// или недоступен → пустой список, без ошибки — это допустимое пустое состояние.

import Foundation

enum FineTuneDatasetScanner {
    static func scan(fineTuneRoot: URL) -> [FineTuneDataset] {
        var result: [FineTuneDataset] = []
        if let root = dataset(workdir: ".", rootURL: fineTuneRoot) {
            result.append(root)
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: fineTuneRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return result }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if let dataset = dataset(workdir: entry.lastPathComponent, rootURL: entry) {
                result.append(dataset)
            }
        }
        return result
    }

    /// Число непустых строк — файл читается целиком (датасеты — единицы МБ), не построчным `FileHandle`.
    static func lineCount(of url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// `dataURL`/`metaURL` — конкретный jsonl-файл (train.jsonl/valid.jsonl и его sidecar);
    /// сопоставление с метаданными — по индексу строки, sidecar может отсутствовать или быть короче.
    static func examples(dataURL: URL, metaURL: URL?) -> [FineTuneExample] {
        guard let text = try? String(contentsOf: dataURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let metaLines: [String] = metaURL
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) } ?? []

        return lines.enumerated().compactMap { index, line in
            guard let body = FineTuneJSONL.parseExample(line: line) else { return nil }
            let meta = index < metaLines.count ? FineTuneJSONL.parseMeta(line: metaLines[index]) : nil
            return FineTuneExample(id: index, system: body.system, user: body.user,
                                   assistant: body.assistant, meta: meta)
        }
    }

    private static func dataset(workdir: String, rootURL: URL) -> FineTuneDataset? {
        let dataURL = rootURL.appendingPathComponent("data")
        let trainURL = dataURL.appendingPathComponent("train.jsonl")
        guard FileManager.default.fileExists(atPath: trainURL.path) else { return nil }

        let splitURL = dataURL.appendingPathComponent("split.json")
        let split: FineTuneSplitInfo? = (try? Data(contentsOf: splitURL))
            .flatMap { try? JSONDecoder().decode(FineTuneSplitInfo.self, from: $0) }
        let systemPromptURL = rootURL.appendingPathComponent("system_prompt.txt")
        let baselineURL = rootURL.appendingPathComponent("baseline")
        let criteriaURL = rootURL.appendingPathComponent("criteria.md")
        let tunedURL = rootURL.appendingPathComponent("tuned")

        return FineTuneDataset(
            id: workdir,
            title: workdir == "." ? rootURL.lastPathComponent : workdir,
            workdir: workdir,
            rootURL: rootURL,
            dataURL: dataURL,
            trainCount: lineCount(of: trainURL),
            validCount: lineCount(of: dataURL.appendingPathComponent("valid.jsonl")),
            split: split,
            systemPromptPath: FileManager.default.fileExists(atPath: systemPromptURL.path)
                ? systemPromptURL.path : nil,
            baselineURL: isDirectory(baselineURL) ? baselineURL : nil,
            criteriaURL: FileManager.default.fileExists(atPath: criteriaURL.path) ? criteriaURL : nil,
            tunedURL: hasFiles(in: tunedURL) ? tunedURL : nil)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    /// Пустой каталог `tuned/` (например, только что созданный) не считается снятым
    /// снимком — нужен хотя бы один файл внутри.
    private static func hasFiles(in url: URL) -> Bool {
        guard isDirectory(url) else { return false }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return !entries.isEmpty
    }
}
