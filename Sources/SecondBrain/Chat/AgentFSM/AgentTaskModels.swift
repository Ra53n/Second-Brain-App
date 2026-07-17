// AgentTaskModels.swift — доменная модель FSM-прогона ответа в чате (задача 35).
//
// Порт паттерна TaskState/TaskFSM/TaskContext из Manager Assistant (Models.swift):
//  - AgentTaskState: этапы прогона planning → execution → validation → answer;
//  - AgentFSM.transitions: ТАБЛИЦА переходов — единственный источник истины,
//    любой переход вне таблицы запрещён (детерминизм на уровне кода);
//  - AgentRunStatus: статус прогона ПОВЕРХ этапа (как MeetingRunStatus);
//  - AgentTaskContext: персистентный контекст прогона (Codable, снисходительный
//    init(from:) — каждый ключ через decodeIfPresent).
//
// Ключевая гарантия: прогон завершается ТОЛЬКО терминальным answer (или явной
// паузой/ошибкой) — модель не решает, «закончила» ли она; переходы решает код,
// бюджеты ретраев при исчерпании форсируют answer (см. AgentPhaseReducer).
//
// Crash-safety: контекст живёт внутри Chat и сохраняется в chats.json после
// каждого перехода; на старте приложения зависшие running → paused.

import Foundation

/// Этап FSM-прогона. Допустимость переходов задаёт ТАБЛИЦА AgentFSM.transitions.
/// `.answer` — терминал, но его вывод — именно ОТВЕТ на задачу пользователя.
enum AgentTaskState: String, Codable, CaseIterable, Identifiable {
    case planning, execution, validation, answer

    var id: String { rawValue }

    /// Снисходительное декодирование: неизвестный этап → .planning
    /// (прогон переиграет с начала — фазы идемпотентны).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentTaskState(rawValue: raw) ?? .planning
    }

    var label: String {
        switch self {
        case .planning: return "Планирование"
        case .execution: return "Выполнение"
        case .validation: return "Проверка"
        case .answer: return "Ответ"
        }
    }
}

/// Детерминированный конечный автомат: единственный источник истины о том,
/// из какого этапа в какие МОЖНО перейти. Таблица — точный порт TaskFSM из MA.
enum AgentFSM {
    static let transitions: [AgentTaskState: [AgentTaskState]] = [
        .planning:   [.execution],                       // только вперёд
        .execution:  [.validation, .planning],           // вперёд ИЛИ перепланировать
        .validation: [.answer, .execution, .planning],   // вперёд / переделать / перепланировать
        .answer:     []                                  // терминал
    ]

    /// Разрешён ли переход from → to по таблице.
    static func allows(_ from: AgentTaskState, to: AgentTaskState) -> Bool {
        transitions[from, default: []].contains(to)
    }
}

/// Статус прогона поверх этапа: этап говорит «что делаем», статус — «жив ли прогон».
enum AgentRunStatus: String, Codable {
    case running   // фаза в полёте (есть живой Task)
    case paused    // остановлен (рестарт приложения / отмена) — можно продолжить
    case failed    // фаза упала с ошибкой (не отмена) — можно продолжить
    case finished  // дошли до answer (терминал)

    /// Снисходительное декодирование: неизвестное → .paused (всегда возобновляемо).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentRunStatus(rawValue: raw) ?? .paused
    }
}

/// Персистентный контекст FSM-прогона — аналог TaskContext из MA.
/// Поля task/state/step/total/plan/done/current — формальная модель;
/// остальные — служебные для оркестрации и персистентности.
struct AgentTaskContext: Codable, Identifiable, Equatable {
    var id = UUID()
    // --- формальная модель ---
    var task: String                        // исходный запрос пользователя
    var state: AgentTaskState = .planning   // текущий этап автомата
    var step: Int = 0                       // индекс текущего шага выполнения (0-based)
    var total: Int = 0                      // всего шагов (= plan.count)
    var plan: [String] = []                 // план — список шагов
    var done: [String] = []                 // результаты выполненных шагов
    var current: String = ""                // текущий шаг (текст)
    // --- оркестрация ---
    var status: AgentRunStatus = .running
    var validationResult: String = ""       // вывод последней Проверки
    var validationPassed: Bool? = nil       // распарсенный вердикт
    var answer: String = ""                 // финальный ответ пользователю
    var executionRetries: Int = 0           // возвраты Проверка → Выполнение
    var planRetries: Int = 0                // возвраты Выполнение → Планирование
    var planFeedback: String = ""           // причина перепланирования (маркер REPLAN)
    var errorText: String? = nil
    var startedAt: Date = Date()

    /// Лимиты возвратов: при исчерпании прогон форсированно идёт в answer.
    static let maxExecutionRetries = 2
    static let maxPlanRetries = 2

    enum CodingKeys: String, CodingKey {
        case id, task, state, step, total, plan, done, current
        case status, validationResult, validationPassed, answer
        case executionRetries, planRetries, planFeedback, errorText, startedAt
    }

    init(task: String) {
        self.task = task
    }

    /// Миграционно-устойчивое декодирование (паттерн TaskContext/MeetingContext):
    /// каждый ключ через decodeIfPresent с дефолтом — старый JSON грузится всегда.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        state = try c.decodeIfPresent(AgentTaskState.self, forKey: .state) ?? .planning
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        plan = try c.decodeIfPresent([String].self, forKey: .plan) ?? []
        done = try c.decodeIfPresent([String].self, forKey: .done) ?? []
        current = try c.decodeIfPresent(String.self, forKey: .current) ?? ""
        status = try c.decodeIfPresent(AgentRunStatus.self, forKey: .status) ?? .paused
        validationResult = try c.decodeIfPresent(String.self, forKey: .validationResult) ?? ""
        validationPassed = try c.decodeIfPresent(Bool.self, forKey: .validationPassed)
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        executionRetries = try c.decodeIfPresent(Int.self, forKey: .executionRetries) ?? 0
        planRetries = try c.decodeIfPresent(Int.self, forKey: .planRetries) ?? 0
        planFeedback = try c.decodeIfPresent(String.self, forKey: .planFeedback) ?? ""
        errorText = try c.decodeIfPresent(String.self, forKey: .errorText)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
    }

    /// Детерминированный переход по таблице. Нелегальный скачок (например
    /// planning → answer) — ошибка программиста (precondition, как в MA):
    /// в рантайме такого быть не может — все переходы производит редьюсер.
    func transitioned(to target: AgentTaskState) -> AgentTaskContext {
        precondition(AgentFSM.allows(state, to: target),
                     "Недопустимый переход \(state.rawValue) → \(target.rawValue)")
        var c = self
        c.state = target
        return c
    }
}
