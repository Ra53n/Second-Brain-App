// types.ts — доменная модель FSM execution loop. Порт паттерна
// Sources/SecondBrain/Chat/AgentFSM/AgentTaskModels.swift на TypeScript.
//
// Два ортогональных измерения: `state` (этап цикла — что делаем) и `status`
// (жив ли прогон). Смешивать нельзя — как в приложении.

/** Этап цикла. `done` терминален. */
export type RunState = "generating" | "testing" | "securityReview" | "committing" | "done";

/** Жив ли прогон. */
export type RunStatus = "running" | "paused" | "failed" | "finished";

/** Терминальный исход (для журнала и отчёта). */
export type RunOutcome =
  | "committed"
  | "stopped-limit"
  | "gateway-blocked"
  | "verdict-unparsed"
  | "failed";

export const ALL_STATES: RunState[] = [
  "generating",
  "testing",
  "securityReview",
  "committing",
  "done",
];

/**
 * Таблица переходов — единственный источник истины (как AgentFSM.transitions).
 *   generating → testing              сгенерировали код, компилируем
 *   testing    → securityReview       собралось, проверяем безопасность
 *   testing    → generating           не собралось, чиним по ошибкам
 *   securityReview → committing        чисто / только Medium-Low
 *   securityReview → generating        Critical/High, чиним по фидбеку
 *   committing → done                  закоммитили
 *   done       → []                    терминал
 */
export const TRANSITIONS: Record<RunState, RunState[]> = {
  generating: ["testing"],
  testing: ["securityReview", "generating"],
  securityReview: ["committing", "generating"],
  committing: ["done"],
  done: [],
};

export function allows(from: RunState, to: RunState): boolean {
  return TRANSITIONS[from].includes(to);
}

/** Одна находка security review. */
export interface Finding {
  severity: "critical" | "high" | "medium" | "low";
  line: number | null;
  issue: string;
}

/**
 * Весь стейт прогона в одной структуре — персистится целиком (как
 * AgentTaskContext). Снисходительный декодер живёт в store/runsRepo.
 */
export interface RunContext {
  id: string;
  taskId: string;
  taskTitle: string;
  taskPrompt: string;
  secure: boolean;

  state: RunState;
  status: RunStatus;
  round: number; // текущий круг (1-based), растёт при возврате на генерацию
  maxRounds: number;

  code: string; // последний сгенерированный код
  buildErrors: string; // хвост ошибок node --check (для фидбека)
  findings: Finding[]; // находки последнего security review
  warnings: string[]; // накопленные Medium/Low
  feedback: string; // фидбек следующей генерации (build или security)

  outcome: RunOutcome | null;
  errorText: string | null;
  pwned: boolean; // канарейка утекла в ответе
  costUsd: number; // накопленная стоимость прогона
  startedAt: string;
}

/** Событие фазы, которое получает редьюсер (уже как результат I/O). */
export type PhaseEvent =
  | { kind: "generated"; code: string | null; truncated: boolean; gatewayBlocked: boolean }
  | { kind: "tested"; ok: boolean; errors: string }
  | { kind: "reviewed"; findings: Finding[] | null; gatewayBlocked: boolean }
  | { kind: "committed" };

export interface Outcome {
  ctx: RunContext;
  /** Человекочитаемая строка для ленты фаз. */
  display: string;
  isTerminal: boolean;
}
