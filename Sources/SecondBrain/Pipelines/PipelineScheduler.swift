// PipelineScheduler.swift — планировщик cron-пайплайнов (задача 36).
//
// Два слоя (эталон AutoBackup): чистая решающая логика PipelineScheduling
// (тестируется мок-датами без таймеров) и тонкий владелец минутного тика.
// Приложение — desktop без сервера: при выключенном приложении слоты не
// срабатывают; политика пропуска — как в MA scheduler.ts: при старте считается
// РОВНО один пропущенный слот (nextDate после последнего прогона), факт
// пропуска всегда фиксируется записью missed, а догоняющий прогон запускается
// только при включённом catchUpOnStart. Дедуп двойного срабатывания — по
// PipelineRun.scheduledFor (история — источник истины, отдельного lastRun нет).

import AppKit
import Foundation

/// Чистая логика планирования.
enum PipelineScheduling {
    /// Пайплайны, чей cron-слот совпал с минутой now (enabled, .cron-триггер,
    /// валидное выражение). Слот = now с обнулёнными секундами. Пайплайн с уже
    /// записанным прогоном этого слота пропускается (дедуп тика/рестарта).
    static func duePipelines(_ pipelines: [PipelineConfig],
                             latestRun: (UUID) -> PipelineRun?,
                             now: Date,
                             calendar: Calendar = .current) -> [(pipeline: PipelineConfig, slot: Date)] {
        let seconds = calendar.component(.second, from: now)
        let sub = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        let slot = now.addingTimeInterval(-Double(seconds) - sub)
        var due: [(PipelineConfig, Date)] = []
        for pipeline in pipelines where pipeline.enabled {
            guard case .cron(let expression) = pipeline.trigger,
                  let cron = CronExpression.parse(expression),
                  cron.matches(slot, calendar: calendar),
                  latestRun(pipeline.id)?.scheduledFor != slot
            else { continue }
            due.append((pipeline, slot))
        }
        return due
    }

    /// Решение catch-up при старте приложения.
    enum CatchUp: Equatable {
        case none
        /// Флаг выключен: только запись missed (факт пропуска не теряем).
        case missedOnly(slot: Date)
        /// Флаг включён: запись missed + один догоняющий прогон.
        case runCatchUp(slot: Date)
    }

    /// Ровно ОДИН пропущенный слот: nextDate после якоря (слот/старт последнего
    /// прогона, иначе создание пайплайна). Слот в будущем либо уже отражённый
    /// в истории (защита от дублей при рестартах) → .none.
    static func catchUpDecision(pipeline: PipelineConfig,
                                latestRun: PipelineRun?,
                                now: Date,
                                calendar: Calendar = .current) -> CatchUp {
        guard pipeline.enabled,
              case .cron(let expression) = pipeline.trigger,
              let cron = CronExpression.parse(expression) else { return .none }
        let anchor = latestRun?.scheduledFor ?? latestRun?.startedAt ?? pipeline.createdAt
        guard let missedSlot = cron.nextDate(after: anchor, calendar: calendar),
              missedSlot <= now,
              latestRun?.scheduledFor != missedSlot else { return .none }
        return pipeline.catchUpOnStart ? .runCatchUp(slot: missedSlot)
                                       : .missedOnly(slot: missedSlot)
    }
}

/// Владелец минутного тика. Жизненный цикл — правило проекта: цикл гасится
/// при willTerminate (start подписывается сам), плюс stop() для тестов/AppModel.
@MainActor
final class PipelineScheduler {
    private let store: PipelineStore
    private let engine: PipelineEngine
    private var tickTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?

    init(store: PipelineStore, engine: PipelineEngine) {
        self.store = store
        self.engine = engine
    }

    /// Идемпотентный старт: catch-up один раз + минутный цикл.
    func start() {
        guard tickTask == nil else { return }
        performCatchUp(now: Date())
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                // Сон до границы следующей минуты (+0.5 c запаса, чтобы тик
                // гарантированно попал в новую минуту).
                let now = Date()
                let untilBoundary = 60 - now.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: 60)
                try? await Task.sleep(nanoseconds: UInt64((untilBoundary + 0.5) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.tick(now: Date())
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
                self?.store.persistNow()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Один тик: подошедшие пайплайны — в движок, каждый своим Task (overlap
    /// guard внутри движка; медленный прогон не задерживает соседей).
    func tick(now: Date = Date()) {
        let due = PipelineScheduling.duePipelines(store.pipelines,
                                                  latestRun: store.latestRun(pipelineID:),
                                                  now: now)
        for (pipeline, slot) in due {
            Task { await self.engine.run(pipeline, trigger: .cron, scheduledFor: slot) }
        }
    }

    /// Catch-up при старте (см. PipelineScheduling.catchUpDecision).
    private func performCatchUp(now: Date) {
        for pipeline in store.pipelines {
            let decision = PipelineScheduling.catchUpDecision(
                pipeline: pipeline,
                latestRun: store.latestRun(pipelineID: pipeline.id),
                now: now)
            switch decision {
            case .none:
                continue
            case .missedOnly(let slot):
                recordMissed(pipeline, slot: slot)
            case .runCatchUp(let slot):
                recordMissed(pipeline, slot: slot)
                Task { await self.engine.run(pipeline, trigger: .catchUp, scheduledFor: slot) }
            }
        }
    }

    /// Факт пропуска фиксируется всегда — история честно показывает дыру.
    private func recordMissed(_ pipeline: PipelineConfig, slot: Date) {
        var run = PipelineRun(pipelineID: pipeline.id, trigger: .cron)
        run.scheduledFor = slot
        run.status = .missed
        run.errorText = "Слот пропущен: приложение не было запущено."
        run.finishedAt = run.startedAt
        store.appendRun(run)
    }
}
