// AgentPromptsTests.swift — задача 35: парсеры и сборка промптов FSM-прогона
// (порт покрытия PipelinePrompts из MA: план, маркеры, вердикт, диалог).

import XCTest
@testable import SecondBrain

final class AgentPromptsTests: XCTestCase {

    // MARK: - parsePlanSteps

    func testParseNumberedPlan() {
        let steps = AgentPrompts.parsePlanSteps("1. Первый шаг\n2) Второй шаг\n3. Третий")
        XCTAssertEqual(steps, ["Первый шаг", "Второй шаг", "Третий"])
    }

    func testParseBulletedPlan() {
        let steps = AgentPrompts.parsePlanSteps("- альфа\n• бета\n* гамма")
        XCTAssertEqual(steps, ["альфа", "бета", "гамма"])
    }

    func testParsePlanSkipsEmptyLines() {
        let steps = AgentPrompts.parsePlanSteps("1. один\n\n\n2. два\n")
        XCTAssertEqual(steps, ["один", "два"])
    }

    /// Планировщик включил протокольный маркер как «шаг» — отбрасываем:
    /// после очистки он невыполним и зациклил бы проверку.
    func testParsePlanDropsMarkerArtifactSteps() {
        let steps = AgentPrompts.parsePlanSteps(
            "1. Сделать дело\n2. Заверши ответ строкой NEXT_STEP\n3. Ещё дело")
        XCTAssertEqual(steps, ["Сделать дело", "Ещё дело"])
    }

    /// Текст без нумерации — весь текст одним шагом (снисходительность).
    func testParsePlanFallsBackToWholeText() {
        XCTAssertEqual(AgentPrompts.parsePlanSteps("просто сделать всё сразу"),
                       ["просто сделать всё сразу"])
    }

    /// Пустой/пробельный текст → пустой план (оркестратор ретраит).
    func testParsePlanEmptyTextGivesEmptyPlan() {
        XCTAssertEqual(AgentPrompts.parsePlanSteps("   \n  "), [])
    }

    // MARK: - Маркеры

    func testMarkersCaseInsensitive() {
        XCTAssertTrue(AgentPrompts.wantsNextStep("готово\nnext_step"))
        XCTAssertTrue(AgentPrompts.wantsReplan("не выйдет, Replan"))
        XCTAssertFalse(AgentPrompts.wantsNextStep("обычный текст"))
        XCTAssertFalse(AgentPrompts.wantsReplan("обычный текст"))
    }

    func testStripMarkersRemovesAll() {
        let stripped = AgentPrompts.stripMarkers("Результат шага\nNEXT_STEP")
        XCTAssertEqual(stripped, "Результат шага")
        XCTAssertEqual(AgentPrompts.stripMarkers("REPLAN"), "")
    }

    // MARK: - parseVerdict

    func testVerdictDone() {
        XCTAssertTrue(AgentPrompts.parseVerdict("Всё сходится.\nВЕРДИКТ: ВЫПОЛНЕНО"))
    }

    func testVerdictNotDone() {
        XCTAssertFalse(AgentPrompts.parseVerdict("Шаг 2 не сделан.\nВЕРДИКТ: НЕ ВЫПОЛНЕНО"))
    }

    /// Отсутствие/неоднозначность вердикта → true (повторы ограничены лимитом).
    func testVerdictMissingDefaultsToTrue() {
        XCTAssertTrue(AgentPrompts.parseVerdict("модель забыла вердикт"))
    }

    /// Последний «ВЕРДИКТ:» выигрывает.
    func testVerdictLastWins() {
        XCTAssertFalse(AgentPrompts.parseVerdict(
            "ВЕРДИКТ: ВЫПОЛНЕНО\nхотя нет, передумал…\nВЕРДИКТ: НЕ ВЫПОЛНЕНО"))
    }

    func testVerdictCaseInsensitive() {
        XCTAssertFalse(AgentPrompts.parseVerdict("вердикт: не выполнено"))
    }

    // MARK: - buildPrompt

    func testBuildPromptContainsStructuralBlocks() {
        var ctx = AgentTaskContext(task: "написать скрипт")
        ctx.state = .execution
        ctx.plan = ["раз", "два"]
        ctx.done = ["сделано раз"]
        ctx.current = "два"
        ctx.step = 1
        ctx.total = 2
        let prompt = AgentPrompts.buildPrompt(query: ctx.task, ctx: ctx)
        XCTAssertTrue(prompt.contains("[STATE]    execution, шаг 2/2"))
        XCTAssertTrue(prompt.contains("[CURRENT]  два"))
        XCTAssertTrue(prompt.contains("[PLAN]"))
        XCTAssertTrue(prompt.contains("1. раз"))
        XCTAssertTrue(prompt.contains("[DONE]"))
        XCTAssertTrue(prompt.contains("[QUERY]    написать скрипт"))
        XCTAssertTrue(prompt.contains("NEXT_STEP"))
    }

    /// Замечания проверки попадают в промпт ТОЛЬКО при повторе выполнения.
    func testValidationFeedbackOnlyOnExecutionRetry() {
        var ctx = AgentTaskContext(task: "т")
        ctx.state = .execution
        ctx.plan = ["шаг"]
        ctx.validationResult = "шаг сделан не так"
        XCTAssertFalse(AgentPrompts.buildPrompt(query: "т", ctx: ctx)
            .contains("ЗАМЕЧАНИЯ ПРОВЕРКИ"), "без ретрая замечания не кладём")
        ctx.executionRetries = 1
        XCTAssertTrue(AgentPrompts.buildPrompt(query: "т", ctx: ctx)
            .contains("[ЗАМЕЧАНИЯ ПРОВЕРКИ — учти при переделке]\nшаг сделан не так"))
    }

    /// Причина перепланирования — только на этапе планирования.
    func testPlanFeedbackOnlyOnPlanning() {
        var ctx = AgentTaskContext(task: "т")
        ctx.planFeedback = "план не учёл API"
        ctx.state = .planning
        XCTAssertTrue(AgentPrompts.buildPrompt(query: "т", ctx: ctx)
            .contains("[ПРИЧИНА ПЕРЕПЛАНИРОВАНИЯ / ПРАВКИ]\nплан не учёл API"))
        ctx.state = .execution
        ctx.plan = ["шаг"]
        XCTAssertFalse(AgentPrompts.buildPrompt(query: "т", ctx: ctx)
            .contains("ПРИЧИНА ПЕРЕПЛАНИРОВАНИЯ"))
    }

    func testRagAndDialogBlocksAppended() {
        let ctx = AgentTaskContext(task: "т")
        let prompt = AgentPrompts.buildPrompt(query: "т", ctx: ctx,
                                              rag: "[RAG_CONTEXT]\nфрагмент",
                                              dialog: "Пользователь: привет")
        XCTAssertTrue(prompt.contains("[RAG_CONTEXT]\nфрагмент"))
        XCTAssertTrue(prompt.contains("[КОНТЕКСТ ДИАЛОГА"))
        XCTAssertTrue(prompt.contains("Пользователь: привет"))
        // Пустые блоки не добавляются.
        let bare = AgentPrompts.buildPrompt(query: "т", ctx: ctx)
        XCTAssertFalse(bare.contains("[КОНТЕКСТ ДИАЛОГА"))
    }

    // MARK: - dialogContext

    /// Промежуточные этапы (planning/execution/validation) — шум: в контекст
    /// диалога идут только реплики пользователя и финальные ответы.
    func testDialogContextFiltersIntermediatePhases() {
        var planMsg = ChatMessage(role: .assistant, content: "план")
        planMsg.agentState = .planning
        var stepMsg = ChatMessage(role: .assistant, content: "шаг")
        stepMsg.agentState = .execution
        var answerMsg = ChatMessage(role: .assistant, content: "итоговый ответ")
        answerMsg.agentState = .answer
        let messages = [
            ChatMessage(role: .user, content: "вопрос"),
            planMsg, stepMsg, answerMsg,
            ChatMessage(role: .assistant, content: "обычный ответ"),
        ]
        let dialog = AgentPrompts.dialogContext(messages: messages)
        XCTAssertTrue(dialog.contains("Пользователь: вопрос"))
        XCTAssertTrue(dialog.contains("Ассистент: итоговый ответ"))
        XCTAssertTrue(dialog.contains("Ассистент: обычный ответ"))
        XCTAssertFalse(dialog.contains("план"))
        XCTAssertFalse(dialog.contains("шаг"))
    }

    func testDialogContextCapsTurnsAndLength() {
        let messages = (1...10).map { ChatMessage(role: .user, content: "реплика \($0)") }
        let dialog = AgentPrompts.dialogContext(messages: messages, maxTurns: 3)
        XCTAssertFalse(dialog.contains("реплика 7"))
        XCTAssertTrue(dialog.contains("реплика 8"))
        XCTAssertTrue(dialog.contains("реплика 10"))

        let long = [ChatMessage(role: .user, content: String(repeating: "а", count: 1000))]
        let capped = AgentPrompts.dialogContext(messages: long, maxTurnChars: 100)
        XCTAssertLessThan(capped.count, 150)
    }
}
