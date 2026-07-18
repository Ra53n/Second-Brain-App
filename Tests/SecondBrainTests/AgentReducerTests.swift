// AgentReducerTests.swift — задача 35: чистое ядро FSM-прогона. Скриптованные
// тексты фаз прогоняются через AgentPhaseReducer — проверяем happy path,
// ретраи с форс-переходом в answer (гарантия терминального ответа), REPLAN
// и жёсткие гейты normalizeBeforePhase.

import XCTest
@testable import SecondBrain

final class AgentReducerTests: XCTestCase {

    private func running(_ task: String = "задача") -> AgentTaskContext {
        var ctx = AgentTaskContext(task: task)
        ctx.status = .running
        return ctx
    }

    // MARK: - Happy path

    /// План(2) → шаг 1 → шаг 2 → проверка ВЫПОЛНЕНО → ответ (finished).
    func testHappyPathTwoSteps() {
        var ctx = running()

        let planning = AgentPhaseReducer.apply(ctx: ctx, phaseText: "1. раз\n2. два")
        ctx = planning.ctx
        XCTAssertEqual(ctx.state, .execution)
        XCTAssertEqual(ctx.plan, ["раз", "два"])
        XCTAssertEqual(ctx.total, 2)
        XCTAssertEqual(planning.display.state, .planning)
        XCTAssertFalse(planning.isTerminal)

        ctx = AgentPhaseReducer.normalizeBeforePhase(ctx)!
        XCTAssertEqual(ctx.current, "раз")
        let step1 = AgentPhaseReducer.apply(ctx: ctx, phaseText: "результат раз\nNEXT_STEP")
        ctx = step1.ctx
        XCTAssertEqual(ctx.state, .execution, "остался шаг — остаёмся в execution")
        XCTAssertEqual(ctx.done, ["результат раз"])
        XCTAssertEqual(step1.display.step, 0)
        XCTAssertEqual(step1.display.total, 2)

        ctx = AgentPhaseReducer.normalizeBeforePhase(ctx)!
        XCTAssertEqual(ctx.current, "два")
        let step2 = AgentPhaseReducer.apply(ctx: ctx, phaseText: "результат два\nNEXT_STEP")
        ctx = step2.ctx
        XCTAssertEqual(ctx.state, .validation, "все шаги сделаны")
        XCTAssertEqual(ctx.done, ["результат раз", "результат два"])

        let validation = AgentPhaseReducer.apply(ctx: ctx, phaseText: "всё ок\nВЕРДИКТ: ВЫПОЛНЕНО")
        ctx = validation.ctx
        XCTAssertEqual(ctx.state, .answer)
        XCTAssertEqual(ctx.validationPassed, true)

        let answer = AgentPhaseReducer.apply(ctx: ctx, phaseText: "Готовый ответ")
        XCTAssertTrue(answer.isTerminal)
        XCTAssertEqual(answer.ctx.status, .finished)
        XCTAssertEqual(answer.ctx.answer, "Готовый ответ")
        XCTAssertEqual(answer.display.state, .answer)
    }

    // MARK: - Проверка и ретраи

    /// Проваленная проверка сбрасывает done и возвращает в execution с
    /// инкрементом executionRetries.
    func testValidationFailRetriesExecution() {
        var ctx = running()
        ctx.state = .validation
        ctx.plan = ["шаг"]
        ctx.done = ["плохой результат"]
        ctx.step = 1
        ctx.total = 1

        let outcome = AgentPhaseReducer.apply(ctx: ctx, phaseText: "плохо\nВЕРДИКТ: НЕ ВЫПОЛНЕНО")
        XCTAssertEqual(outcome.ctx.state, .execution)
        XCTAssertEqual(outcome.ctx.executionRetries, 1)
        XCTAssertEqual(outcome.ctx.done, [], "переделка с чистого листа")
        XCTAssertEqual(outcome.ctx.step, 0)
    }

    /// Бюджет исчерпан → answer ВСЁ РАВНО: агент не может бросить работу.
    func testValidationFailBudgetExhaustedForcesAnswer() {
        var ctx = running()
        ctx.state = .validation
        ctx.plan = ["шаг"]
        ctx.done = ["результат"]
        ctx.executionRetries = AgentTaskContext.maxExecutionRetries

        let outcome = AgentPhaseReducer.apply(ctx: ctx, phaseText: "ВЕРДИКТ: НЕ ВЫПОЛНЕНО")
        XCTAssertEqual(outcome.ctx.state, .answer,
                       "ретраи кончились — форс-переход к ответу")
        XCTAssertFalse(outcome.isTerminal, "терминал — только сама фаза answer")
    }

    // MARK: - REPLAN

    /// REPLAN на выполнении → назад в планирование с причиной.
    func testReplanGoesBackToPlanning() {
        var ctx = running()
        ctx.state = .execution
        ctx.plan = ["нереальный шаг"]
        ctx.current = "нереальный шаг"
        ctx.total = 1

        let outcome = AgentPhaseReducer.apply(ctx: ctx, phaseText: "план не годится\nREPLAN")
        XCTAssertEqual(outcome.ctx.state, .planning)
        XCTAssertEqual(outcome.ctx.planRetries, 1)
        XCTAssertEqual(outcome.ctx.planFeedback, "план не годится")
        XCTAssertEqual(outcome.ctx.done, [], "шаг не засчитан")
    }

    /// Бюджет REPLAN исчерпан → маркер игнорируется, шаг засчитывается.
    func testReplanBudgetExhaustedTreatsAsStepDone() {
        var ctx = running()
        ctx.state = .execution
        ctx.plan = ["шаг"]
        ctx.total = 1
        ctx.planRetries = AgentTaskContext.maxPlanRetries

        let outcome = AgentPhaseReducer.apply(ctx: ctx, phaseText: "опять не так\nREPLAN")
        XCTAssertEqual(outcome.ctx.state, .validation,
                       "перепланировать больше нельзя — движемся вперёд")
        XCTAssertEqual(outcome.ctx.done, ["опять не так"])
    }

    /// Пустой план: ретрай в бюджете, затем деградация в план из одного шага.
    func testEmptyPlanRetriesThenDegradesToSingleStep() {
        var ctx = running("выполни задачу")

        var outcome = AgentPhaseReducer.apply(ctx: ctx, phaseText: " ")
        XCTAssertEqual(outcome.ctx.state, .planning, "пустой план — остаёмся планировать")
        XCTAssertEqual(outcome.ctx.planRetries, 1)

        outcome.ctx.planRetries = AgentTaskContext.maxPlanRetries
        let degraded = AgentPhaseReducer.apply(ctx: outcome.ctx, phaseText: " ")
        XCTAssertEqual(degraded.ctx.state, .execution)
        XCTAssertEqual(degraded.ctx.plan, ["выполни задачу"],
                       "деградация: задача целиком одним шагом")
    }

    // MARK: - Жёсткие гейты

    /// Проверка без единого выполненного шага → назад в execution.
    func testGateValidationWithEmptyDone() {
        var ctx = running()
        ctx.state = .validation
        ctx.plan = ["шаг"]
        let normalized = AgentPhaseReducer.normalizeBeforePhase(ctx)
        XCTAssertEqual(normalized?.state, .execution)
    }

    /// Выполнение без плана → назад в planning.
    func testGateExecutionWithEmptyPlan() {
        var ctx = running()
        ctx.state = .execution
        let normalized = AgentPhaseReducer.normalizeBeforePhase(ctx)
        XCTAssertEqual(normalized?.state, .planning)
    }

    /// Ответ без результата проверки — продолжать нельзя (nil).
    func testGateAnswerWithoutValidationBlocks() {
        var ctx = running()
        ctx.state = .answer
        XCTAssertNil(AgentPhaseReducer.normalizeBeforePhase(ctx))
        ctx.validationResult = "проверено"
        XCTAssertNotNil(AgentPhaseReducer.normalizeBeforePhase(ctx))
    }

    /// Шаг за пределами плана (битый JSON) зажимается в границы.
    func testGateClampsStepAndFillsCurrent() {
        var ctx = running()
        ctx.state = .execution
        ctx.plan = ["раз", "два"]
        ctx.step = 99
        let normalized = AgentPhaseReducer.normalizeBeforePhase(ctx)!
        XCTAssertEqual(normalized.step, 1)
        XCTAssertEqual(normalized.current, "два")
        XCTAssertEqual(normalized.total, 2)
    }
}
