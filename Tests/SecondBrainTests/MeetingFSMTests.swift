// MeetingFSMTests.swift — исчерпывающая проверка таблицы переходов пайплайна
// встречи (порт паттерна FSMTests из MA): эталонная таблица + перебор ВСЕХ
// упорядоченных пар состояний, терминальность, guarded transitioned(to:).

import XCTest
@testable import SecondBrain

final class MeetingFSMTests: XCTestCase {

    /// Эталонная таблица допустимых переходов — единственный источник истины.
    private let expected: [MeetingState: Set<MeetingState>] = [
        .recorded:      [.transcribing],
        .transcribing:  [.transcribed, .failed],
        .transcribed:   [.summarizing],
        .summarizing:   [.awaitingTitle, .filing, .failed],
        .awaitingTitle: [.filing],
        .filing:        [.done, .failed],
        .failed:        [.transcribing, .summarizing, .filing],
        .done:          [],
    ]

    /// allows() для ВСЕХ упорядоченных пар совпадает с эталоном.
    func testAllowsMatchesTableForEveryPair() {
        for from in MeetingState.allCases {
            for to in MeetingState.allCases {
                let want = expected[from, default: []].contains(to)
                XCTAssertEqual(MeetingFSM.allows(from, to: to), want,
                               "\(from.rawValue) → \(to.rawValue): ожидали \(want)")
            }
        }
    }

    /// Таблица в коде ровно та же, что эталон (ловит добавление/удаление стрелок).
    func testTransitionsTableExact() {
        XCTAssertEqual(Set(MeetingFSM.transitions.keys), Set(MeetingState.allCases),
                       "каждое состояние должно быть в таблице")
        for from in MeetingState.allCases {
            XCTAssertEqual(Set(MeetingFSM.transitions[from, default: []]),
                           expected[from, default: []],
                           "переходы из \(from.rawValue) не совпали")
        }
    }

    /// done — терминал: из него нельзя никуда.
    func testDoneIsTerminal() {
        for to in MeetingState.allCases {
            XCTAssertFalse(MeetingFSM.allows(.done, to: to))
        }
    }

    /// В done можно ТОЛЬКО из filing (заметка обязана быть записана).
    func testDoneOnlyFromFiling() {
        for from in MeetingState.allCases {
            XCTAssertEqual(MeetingFSM.allows(from, to: .done), from == .filing,
                           "в done можно только из filing — пробовали из \(from.rawValue)")
        }
    }

    /// В filing три легальных входа: summarizing (авто), awaitingTitle
    /// (подтверждение), failed (ретрай).
    func testFilingEntries() {
        for from in MeetingState.allCases {
            let want: Bool = [.summarizing, .awaitingTitle, .failed].contains(from)
            XCTAssertEqual(MeetingFSM.allows(from, to: .filing), want)
        }
    }

    /// transitioned(to:) по легальной стрелке сохраняет id и артефакты.
    func testTransitionedKeepsIdentity() {
        var context = MeetingContext(recordingBase: "b", audioFiles: ["b.m4a"],
                                     recordedAt: .now, duration: 60)
        context.summary = "конспект"
        let moved = context.transitioned(to: .transcribing)
        XCTAssertEqual(moved.state, .transcribing)
        XCTAssertEqual(moved.id, context.id)
        XCTAssertEqual(moved.summary, "конспект")
    }
}
