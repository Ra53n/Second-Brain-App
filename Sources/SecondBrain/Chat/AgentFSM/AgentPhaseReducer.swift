// AgentPhaseReducer.swift — чистое ядро FSM-прогона (задача 35).
//
// Порт per-state switch из runStateMachine MA (ChatViewModel.swift:933-1024),
// вынесенный в ЧИСТУЮ функцию «контекст + текст фазы → новый контекст +
// сообщение для ленты»: все переходы состояний происходят ТОЛЬКО здесь и
// только через ctx.transitioned(to:) — оркестратор лишь гоняет LLM и
// персистит результат. Чистота = исчерпываемая тестируемость без моков LLM.
//
// Гарантия терминального ответа: validation-fail расходует executionRetries
// (2), REPLAN расходует planRetries (2); при исчерпании бюджета прогон
// форсированно идёт в answer — модель не может ни зациклить, ни бросить работу.

import Foundation

enum AgentPhaseReducer {
    /// Сообщение фазы для ленты чата (текст уже очищен от маркеров).
    struct DisplayMessage: Equatable {
        var text: String
        var state: AgentTaskState
        var step: Int?   // только для execution
        var total: Int?  // только для execution
    }

    /// Итог применения фазы.
    struct Outcome: Equatable {
        var ctx: AgentTaskContext
        var display: DisplayMessage
        /// true — прогон завершён (answer выдан, status == .finished).
        var isTerminal: Bool
    }

    /// Жёсткая готовность этапа (последний рубеж на уровне кода, порт MA):
    /// НЕ генерируем промпт стадии без РЕАЛЬНОГО результата предыдущей.
    /// Возвращает контекст, готовый к фазе (возможно, с переходом назад),
    /// либо nil — прогон невозможно продолжить (answer без результата
    /// проверки: терминал, назад дороги нет) — оркестратор ставит паузу.
    static func normalizeBeforePhase(_ ctx: AgentTaskContext) -> AgentTaskContext? {
        var c = ctx
        if c.state == .validation, c.done.isEmpty {
            c = c.transitioned(to: .execution)          // нет выполнения — назад
        }
        if c.state == .answer,
           c.validationResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil                                   // терминал без проверки — стоп
        }
        if c.state == .execution {
            guard !c.plan.isEmpty else {
                return c.transitioned(to: .planning)     // плана нет — строить план
            }
            c.total = c.plan.count
            c.step = min(max(0, c.step), c.plan.count - 1)
            c.current = c.plan[c.step]
        }
        return c
    }

    /// Применяет результат фазы: вывод этапа в контекст + сообщение в ленту +
    /// ПЕРЕХОД (только через transitioned). Один вызов = одна фаза (один
    /// запрос модели). `phaseText` — сырой текст модели (с маркерами).
    static func apply(ctx: AgentTaskContext, phaseText: String) -> Outcome {
        var c = ctx
        let pure = AgentPrompts.stripMarkers(phaseText)

        switch c.state {
        case .planning:
            let steps = AgentPrompts.parsePlanSteps(phaseText)
            if steps.isEmpty {
                // Деградация пустого плана: ретрай в рамках бюджета, затем
                // план из одного шага «выполнить задачу целиком» — гарантия
                // терминального ответа сохраняется при любом поведении модели.
                if c.planRetries < AgentTaskContext.maxPlanRetries {
                    c.planRetries += 1
                    c.planFeedback = "План пуст — составь план заново."
                    return Outcome(ctx: c,
                                   display: DisplayMessage(text: pure, state: .planning,
                                                           step: nil, total: nil),
                                   isTerminal: false)
                }
                c.plan = [c.task]
            } else {
                c.plan = steps
            }
            c.total = c.plan.count
            c.done = []
            c.step = 0
            c.current = c.plan.first ?? ""
            c.planFeedback = ""
            c = c.transitioned(to: .execution)
            return Outcome(ctx: c,
                           display: DisplayMessage(text: pure, state: .planning,
                                                   step: nil, total: nil),
                           isTerminal: false)

        case .execution:
            let display = DisplayMessage(text: pure, state: .execution,
                                         step: c.step, total: c.total)
            if AgentPrompts.wantsReplan(phaseText),
               c.planRetries < AgentTaskContext.maxPlanRetries {
                c.planRetries += 1
                c.planFeedback = pure                    // причина → в планирование
                c = c.transitioned(to: .planning)
            } else {
                c.done.append(pure)
                c.step += 1
                if c.step >= c.total {
                    c = c.transitioned(to: .validation)  // все шаги сделаны
                }
                // иначе остаёмся в execution — следующая фаза возьмёт следующий шаг
            }
            return Outcome(ctx: c, display: display, isTerminal: false)

        case .validation:
            c.validationResult = phaseText
            c.validationPassed = AgentPrompts.parseVerdict(phaseText)
            if c.validationPassed == true {
                c = c.transitioned(to: .answer)
            } else if c.executionRetries < AgentTaskContext.maxExecutionRetries {
                c.executionRetries += 1
                c.done = []
                c.step = 0                                // переделать с замечаниями
                c = c.transitioned(to: .execution)
            } else {
                c = c.transitioned(to: .answer)           // бюджет исчерпан — отвечаем как есть
            }
            return Outcome(ctx: c,
                           display: DisplayMessage(text: pure, state: .validation,
                                                   step: nil, total: nil),
                           isTerminal: false)

        case .answer:
            c.answer = pure
            c.status = .finished                          // терминал
            return Outcome(ctx: c,
                           display: DisplayMessage(text: pure, state: .answer,
                                                   step: nil, total: nil),
                           isTerminal: true)
        }
    }
}
