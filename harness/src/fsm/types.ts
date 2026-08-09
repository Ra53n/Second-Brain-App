// types.ts — доменная модель execution loop чата. Чистый LLM-цикл: генерация
// результата → самопроверка корректности → security review → готово. Без
// исполнения кода. Порт паттерна AgentPhaseReducer.
//
// Два ортогональных измерения: `state` (этап цикла) и `status` (жив ли прогон).

/** Этап цикла. `done` терминален. */
export type RunState = "generating" | "verifying" | "securityReview" | "done";

/** Жив ли прогон. */
export type RunStatus = "running" | "paused" | "failed" | "finished";

/** Терминальный исход (для журнала). */
export type RunOutcome = "done" | "stopped-limit" | "gateway-blocked" | "verdict-unparsed" | "failed";

export const ALL_STATES: RunState[] = ["generating", "verifying", "securityReview", "done"];

/**
 * Таблица переходов — единственный источник истины.
 *   generating     → verifying         получили результат, проверяем корректность
 *   verifying      → securityReview     корректно, проверяем безопасность
 *   verifying      → generating         не корректно, переделываем по замечаниям
 *   securityReview → done               чисто / только Medium-Low
 *   securityReview → generating         Critical/High, переделываем по фидбеку
 *   done           → []                 терминал
 */
export const TRANSITIONS: Record<RunState, RunState[]> = {
  generating: ["verifying"],
  verifying: ["securityReview", "generating"],
  securityReview: ["done", "generating"],
  done: [],
};

export function allows(from: RunState, to: RunState): boolean {
  return TRANSITIONS[from].includes(to);
}

/** Одна находка security review. */
export interface Finding {
  severity: "critical" | "high" | "medium" | "low";
  issue: string;
}

/** Одно замечание проверки корректности. */
export interface CorrectnessVerdict {
  correct: boolean;
  issues: string[];
}

/**
 * Стейт прогона loop в одной структуре (в памяти, на время фонового прогона
 * сообщения). Трейс фаз пишется в store/chatsRepo (message.loop_json).
 */
export interface RunContext {
  id: string;
  taskPrompt: string;

  state: RunState;
  status: RunStatus;
  round: number; // текущий круг (1-based), растёт при возврате на генерацию
  maxRounds: number;

  result: string; // последний сгенерированный результат (после egress-guard)
  correctness: CorrectnessVerdict | null; // вердикт последней проверки корректности
  findings: Finding[]; // находки последнего security review
  warnings: string[]; // накопленные Medium/Low
  feedback: string; // фидбек следующей генерации (корректность или security)

  outcome: RunOutcome | null;
  errorText: string | null;
  pwned: boolean; // канарейка утекла в результате
  costUsd: number;
  startedAt: string;
}

/** Событие фазы для редьюсера (результат уже свершившегося I/O). */
export type PhaseEvent =
  | { kind: "generated"; result: string | null; gatewayBlocked: boolean }
  | { kind: "verified"; verdict: CorrectnessVerdict | null; gatewayBlocked: boolean }
  | { kind: "reviewed"; findings: Finding[] | null; gatewayBlocked: boolean };

export interface Outcome {
  ctx: RunContext;
  /** Человекочитаемая строка для ленты фаз. */
  display: string;
  isTerminal: boolean;
}
