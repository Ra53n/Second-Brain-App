// AgentFSMTests.swift — задача 35: исчерпывающая проверка таблицы переходов
// FSM-прогона чата (порт паттерна FSMTests MA / MeetingFSMTests) + миграции
// AgentTaskContext и новых полей моделей чата.

import XCTest
@testable import SecondBrain

final class AgentFSMTests: XCTestCase {

    /// Эталонная таблица допустимых переходов — единственный источник истины.
    private let expected: [AgentTaskState: Set<AgentTaskState>] = [
        .planning:   [.execution],
        .execution:  [.validation, .planning],
        .validation: [.answer, .execution, .planning],
        .answer:     [],
    ]

    /// allows() для ВСЕХ упорядоченных пар совпадает с эталоном.
    func testAllowsMatchesTableForEveryPair() {
        for from in AgentTaskState.allCases {
            for to in AgentTaskState.allCases {
                let want = expected[from, default: []].contains(to)
                XCTAssertEqual(AgentFSM.allows(from, to: to), want,
                               "\(from.rawValue) → \(to.rawValue): ожидали \(want)")
            }
        }
    }

    /// Таблица в коде ровно та же, что эталон (ловит добавление/удаление стрелок).
    func testTransitionsTableExact() {
        XCTAssertEqual(Set(AgentFSM.transitions.keys), Set(AgentTaskState.allCases),
                       "каждое состояние должно быть в таблице")
        for from in AgentTaskState.allCases {
            XCTAssertEqual(Set(AgentFSM.transitions[from, default: []]),
                           expected[from, default: []],
                           "переходы из \(from.rawValue) не совпали")
        }
    }

    /// answer — терминал: из него нельзя никуда.
    func testAnswerIsTerminal() {
        for to in AgentTaskState.allCases {
            XCTAssertFalse(AgentFSM.allows(.answer, to: to))
        }
    }

    /// В answer можно ТОЛЬКО из validation (проверка обязана состояться).
    func testAnswerOnlyFromValidation() {
        for from in AgentTaskState.allCases {
            XCTAssertEqual(AgentFSM.allows(from, to: .answer), from == .validation,
                           "в answer можно только из validation — пробовали из \(from.rawValue)")
        }
    }

    /// transitioned(to:) по легальной стрелке сохраняет id и артефакты.
    func testTransitionedKeepsIdentity() {
        var context = AgentTaskContext(task: "задача")
        context.plan = ["шаг"]
        let moved = context.transitioned(to: .execution)
        XCTAssertEqual(moved.state, .execution)
        XCTAssertEqual(moved.id, context.id)
        XCTAssertEqual(moved.plan, ["шаг"])
    }
}

// MARK: - Миграции

final class AgentTaskContextMigrationTests: XCTestCase {

    /// Минимальный JSON старого формата декодируется с дефолтами.
    func testMinimalJSONDecodes() throws {
        let json = #"{"task": "сделай"}"#
        let ctx = try JSONDecoder().decode(AgentTaskContext.self, from: Data(json.utf8))
        XCTAssertEqual(ctx.task, "сделай")
        XCTAssertEqual(ctx.state, .planning)
        XCTAssertEqual(ctx.status, .paused, "без статуса — возобновляемо")
        XCTAssertEqual(ctx.plan, [])
        XCTAssertEqual(ctx.executionRetries, 0)
    }

    /// Неизвестные state/status из будущих версий → безопасные дефолты.
    func testUnknownEnumValuesFallBack() throws {
        let json = #"{"task": "т", "state": "swarming", "status": "hyperspace"}"#
        let ctx = try JSONDecoder().decode(AgentTaskContext.self, from: Data(json.utf8))
        XCTAssertEqual(ctx.state, .planning)
        XCTAssertEqual(ctx.status, .paused)
    }

    /// Round-trip контекста середины прогона.
    func testRoundTripMidRun() throws {
        var ctx = AgentTaskContext(task: "задача")
        ctx.state = .execution
        ctx.status = .running
        ctx.plan = ["один", "два"]
        ctx.done = ["результат один"]
        ctx.step = 1
        ctx.total = 2
        ctx.executionRetries = 1
        let data = try JSONEncoder().encode(ctx)
        let decoded = try JSONDecoder().decode(AgentTaskContext.self, from: data)
        XCTAssertEqual(decoded, ctx)
    }

    /// Старый Chat JSON без agentContext/agentModeEnabled декодируется.
    func testOldChatJSONWithoutAgentFieldsDecodes() throws {
        let json = #"{"title": "Старый", "messages": [{"role": "user", "content": "хм"}]}"#
        let chat = try JSONDecoder().decode(Chat.self, from: Data(json.utf8))
        XCTAssertNil(chat.agentContext)
        XCTAssertFalse(chat.configuration.agentModeEnabled)
        XCTAssertNil(chat.messages.first?.agentState)
    }

    /// agentModeEnabled переживает ручной encode(to:) ChatConfiguration.
    func testAgentModeEnabledRoundTrip() throws {
        var configuration = ChatConfiguration()
        configuration.agentModeEnabled = true
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        XCTAssertTrue(decoded.agentModeEnabled)
    }

    /// Теги этапа на сообщении персистятся.
    func testMessageAgentTagsRoundTrip() throws {
        var message = ChatMessage(role: .assistant, content: "результат")
        message.agentState = .execution
        message.agentStep = 1
        message.agentTotal = 3
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.agentState, .execution)
        XCTAssertEqual(decoded.agentStep, 1)
        XCTAssertEqual(decoded.agentTotal, 3)
    }
}
