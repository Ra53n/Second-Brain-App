// FineTuneDatasetImporter.swift — импорт внешнего JSONL в `finetune/<name>` (I/O, задача 83).
//
// Пишет полный набор файлов, которых ждёт python-тулчейн (`validate.py` и далее):
// data/{raw,train,valid}.jsonl + их sidecar .meta.jsonl, data/split.json,
// system_prompt.txt. Ошибка после создания каталога откатывает его целиком —
// половинчатый датасет не должен попасть в список (`FineTuneDatasetScanner`).

import Foundation

enum FineTuneDatasetImporter {
    /// URL может указывать за пределы песочницы (fileImporter) — security scope
    /// оборачивает вызывающий код (ViewModel), здесь только чтение и лимит размера.
    static func readSource(url: URL, maxBytes: Int = 50_000_000) throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? Int, size > maxBytes {
            throw FineTuneImportError.fileTooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw FineTuneImportError.fileUnreadable }
        if data.count > maxBytes { throw FineTuneImportError.fileTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw FineTuneImportError.fileUnreadable }
        return text
    }

    /// Возвращает id/имя нового датасета (совпадает с `FineTuneDataset.id` после
    /// пересканирования — `FineTuneDatasetScanner` берёт его из имени каталога).
    /// `name` — граница модуля: вызывающий код (UI) уже прогоняет его через
    /// `sanitizeName`, но сам `importDataset` доверять этому не должен.
    static func importDataset(from sourceText: String, name: String, into root: URL, seed: UInt64,
                              fileManager: FileManager = .default) throws -> String {
        guard let clean = FineTuneImportCore.sanitizeName(name), clean == name else {
            throw FineTuneImportError.badName(name)
        }
        let parsed = FineTuneImportCore.parse(text: sourceText)
        guard parsed.examples.count >= 2 else {
            throw FineTuneImportError.tooFewExamples(validCount: parsed.examples.count)
        }

        let datasetURL = root.appendingPathComponent(name)
        do {
            try fileManager.createDirectory(at: datasetURL, withIntermediateDirectories: false)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteFileExistsError {
                throw FineTuneImportError.datasetExists(name)
            }
            throw FineTuneImportError.writeFailed(error.localizedDescription)
        }
        do {
            try write(parsed.examples, datasetURL: datasetURL, seed: seed, fileManager: fileManager)
            return name
        } catch {
            try? fileManager.removeItem(at: datasetURL)
            throw error
        }
    }

    private static func write(_ examples: [FineTuneImportCore.ParsedExample], datasetURL: URL, seed: UInt64,
                              fileManager: FileManager) throws {
        let dataURL = datasetURL.appendingPathComponent("data")
        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)

        let split = FineTuneImportCore.split(count: examples.count, seed: seed)
        let allMeta = (0..<examples.count).map { FineTuneImportCore.syntheticMetaLine(index: $0 + 1) }

        try writeJSONL(examples.map(\.rawLine), to: dataURL.appendingPathComponent("raw.jsonl"))
        try writeJSONL(split.train.map { examples[$0].rawLine }, to: dataURL.appendingPathComponent("train.jsonl"))
        try writeJSONL(split.valid.map { examples[$0].rawLine }, to: dataURL.appendingPathComponent("valid.jsonl"))
        try writeJSONL(allMeta, to: dataURL.appendingPathComponent("raw.meta.jsonl"))
        try writeJSONL(split.train.map { allMeta[$0] }, to: dataURL.appendingPathComponent("train.meta.jsonl"))
        try writeJSONL(split.valid.map { allMeta[$0] }, to: dataURL.appendingPathComponent("valid.meta.jsonl"))

        let summary = FineTuneImportCore.splitSummary(seed: seed, trainCount: split.train.count,
                                                       validCount: split.valid.count, evalFraction: 0.2)
        try summary.write(to: dataURL.appendingPathComponent("split.json"), options: .atomic)

        guard let systemData = (examples[0].system + "\n").data(using: .utf8) else {
            throw FineTuneImportError.fileUnreadable
        }
        try systemData.write(to: datasetURL.appendingPathComponent("system_prompt.txt"), options: .atomic)
    }

    private static func writeJSONL(_ lines: [String], to url: URL) throws {
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { throw FineTuneImportError.fileUnreadable }
        try data.write(to: url, options: .atomic)
    }
}

enum FineTuneImportError: LocalizedError, Equatable {
    case fileTooLarge
    case fileUnreadable
    case tooFewExamples(validCount: Int)
    case datasetExists(String)
    case badName(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "Файл больше 50 МБ — выберите файл меньшего размера."
        case .fileUnreadable:
            return "Не удалось прочитать файл — проверьте, что он в кодировке UTF-8."
        case let .tooFewExamples(validCount):
            return "Валидных примеров меньше двух (\(validCount)) — нечего импортировать."
        case let .datasetExists(name):
            return "Датасет «\(name)» уже существует."
        case let .badName(name):
            return "Недопустимое имя датасета: «\(name)»."
        case let .writeFailed(detail):
            return "Не удалось создать датасет: \(detail)"
        }
    }
}
