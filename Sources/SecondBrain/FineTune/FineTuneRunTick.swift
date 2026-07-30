// FineTuneRunTick.swift — один тик наблюдения за прогоном (P1, без I/O).
//
// FineTuneViewModel.tick() делает I/O (kill, readNew, FileManager) и передаёт сюда уже
// готовые факты; здесь только решение, что изменилось в прогоне и в хвосте лога.

import Foundation

enum FineTuneRunTick {
    /// Факты, добытые I/O снаружи секундным таймером.
    struct Input {
        let newLogText: String
        let isProcessAlive: Bool
        let adapterExists: Bool
        let logTailLimit: Int
    }

    struct Outcome {
        let run: FineTuneRun
        /// Хвост лога после ring-буфера — не длиннее `logTailLimit` строк.
        let logLines: [String]
        /// true — pid обнаружен мёртвым в этом тике: прогон завершился или упал.
        let finished: Bool
    }

    static func apply(_ input: Input, to run: FineTuneRun, existingLogLines: [String]) -> Outcome {
        var updated = run
        var lines = existingLogLines
        if !input.newLogText.isEmpty {
            updated.points += FineTuneLogParser.points(in: input.newLogText)
            lines.append(contentsOf: FineTuneLogParser.displayLines(in: input.newLogText, limit: Int.max))
            if lines.count > input.logTailLimit {
                lines.removeFirst(lines.count - input.logTailLimit)
            }
        }

        var finished = false
        if updated.pid != nil, !input.isProcessAlive {
            updated.status = input.adapterExists ? .finished : .failed
            updated.finishedAt = Date()
            if updated.bestIter == nil {
                updated.bestIter = FineTuneCheckpointPicker.best(from: updated.points)?.iter
            }
            finished = true
        }
        return Outcome(run: updated, logLines: lines, finished: finished)
    }
}
