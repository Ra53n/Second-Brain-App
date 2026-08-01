// ConfidenceBatchRunner.swift — батч-прогон confidence pipeline на подборке valid.jsonl
// (задача 85): `<dataset>/confidence/{baseline,tuned}.{json,md}` + `summary.md`, когда
// оба варианта уже сняты. Атомарная запись, крах посреди прогона не пишет файлов.

import Foundation

@MainActor
final class ConfidenceBatchRunner {
    private let redundancyCount: Int

    init(redundancyCount: Int = 3) {
        self.redundancyCount = redundancyCount
    }

    /// Возвращает URL записанного `<variant>.md`. Отмена (`Task.cancel`) пробрасывается
    /// без записи файлов — частичный прогон не оставляет артефактов.
    func run(dataset: FineTuneDataset, variant: FineTuneModelVariant, provider: ChatProvider, system: String,
             onProgress: (Int, Int) -> Void = { _, _ in }) async throws -> URL {
        let validURL = dataset.dataURL.appendingPathComponent("valid.jsonl")
        let text: String
        do {
            text = try String(contentsOf: validURL, encoding: .utf8)
        } catch {
            // Отсутствующий/нечитаемый файл — не «пустая подборка»: молчаливое
            // продолжение записало бы «успешный» отчёт из 0 строк поверх валидного
            // прежнего <variant>.json/md (P6).
            throw FineTuneError.datasetUnreadable(validURL.path)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        var examples: [(index: Int, transcript: String, reference: String)] = []
        for (index, line) in lines.enumerated() {
            guard let body = FineTuneJSONL.parseExample(line: line) else { continue }
            examples.append((index: index, transcript: body.user, reference: body.assistant))
        }
        guard !examples.isEmpty else {
            throw FineTuneError.validSetEmpty(validURL.path)
        }
        let items = ConfidenceBatch.plan(examples: examples)

        let settings = ChatSettings(model: MlxServerConfig.defaultModel, temperature: FineTuneRunner.baselineTemperature)
        // Батч всегда гонит полный пайплайн (задача 86) — сравнение baseline/тюна должно
        // быть одинаковым независимо от тумблеров, выставленных для чата.
        let pipeline = ConfidencePipeline(provider: provider, settings: settings, redundancyCount: redundancyCount,
                                           config: .allEnabled)

        var rows: [BatchRow] = []
        rows.reserveCapacity(items.count)
        for (position, item) in items.enumerated() {
            try Task.checkCancellation()
            onProgress(position + 1, items.count)
            let (_, report) = try await pipeline.run(system: system, transcript: item.transcript, reference: item.reference)
            let passed = report.checks.filter { $0.status == "pass" }.count
            rows.append(BatchRow(
                index: item.index, kind: item.kind, verdict: report.verdict,
                checksPassed: passed, checksTotal: report.checks.count, redundancy: report.redundancy,
                scoringStatus: report.scoringStatus, scoringConfidence: report.scoringConfidence,
                primaryLatency: report.metrics.primaryLatency, totalLatency: report.metrics.totalLatency,
                promptTokens: report.metrics.promptTokens, completionTokens: report.metrics.completionTokens,
                extraCalls: report.metrics.extraCalls))
        }

        return try write(rows: rows, dataset: dataset, variant: variant)
    }

    private func write(rows: [BatchRow], dataset: FineTuneDataset, variant: FineTuneModelVariant) throws -> URL {
        let confidenceDir = dataset.rootURL.appendingPathComponent("confidence")
        try FileManager.default.createDirectory(at: confidenceDir, withIntermediateDirectories: true)

        let jsonURL = confidenceDir.appendingPathComponent("\(variant.rawValue).json")
        let mdURL = confidenceDir.appendingPathComponent("\(variant.rawValue).md")
        try JSONEncoder().encode(rows).write(to: jsonURL, options: .atomic)
        let report = ConfidenceBatch.renderReport(title: "Confidence — \(variant.rawValue)", rows: rows)
        try Data(report.utf8).write(to: mdURL, options: .atomic)

        let other: FineTuneModelVariant = variant == .baseline ? .tuned : .baseline
        let otherURL = confidenceDir.appendingPathComponent("\(other.rawValue).json")
        if let otherData = try? Data(contentsOf: otherURL),
           let otherRows = try? JSONDecoder().decode([BatchRow].self, from: otherData) {
            let baselineRows = variant == .baseline ? rows : otherRows
            let tunedRows = variant == .tuned ? rows : otherRows
            let summary = ConfidenceBatch.renderSummary(baseline: baselineRows, tuned: tunedRows)
            try Data(summary.utf8).write(to: confidenceDir.appendingPathComponent("summary.md"), options: .atomic)
        }
        return mdURL
    }
}
