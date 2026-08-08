// transitions.test.ts — таблица переходов FSM (порт AgentFSMTests): проверяем
// каждую упорядоченную пару против эталона, объявленного отдельно от прода.

import { describe, it, expect } from "vitest";
import { ALL_STATES, allows, TRANSITIONS, type RunState } from "../src/fsm/types.js";

const expected: Record<RunState, Set<RunState>> = {
  generating: new Set<RunState>(["testing"]),
  testing: new Set<RunState>(["securityReview", "generating"]),
  securityReview: new Set<RunState>(["committing", "generating"]),
  committing: new Set<RunState>(["done"]),
  done: new Set<RunState>(),
};

describe("таблица переходов FSM", () => {
  it("allows совпадает с эталоном для каждой пары", () => {
    for (const from of ALL_STATES) {
      for (const to of ALL_STATES) {
        expect(allows(from, to), `${from} → ${to}`).toBe(expected[from].has(to));
      }
    }
  });

  it("done терминален", () => {
    expect(TRANSITIONS.done).toEqual([]);
  });

  it("каждое состояние присутствует в таблице", () => {
    for (const s of ALL_STATES) {
      expect(TRANSITIONS[s]).toBeDefined();
    }
  });

  it("в committing можно попасть только из securityReview", () => {
    const sources = ALL_STATES.filter((s) => allows(s, "committing"));
    expect(sources).toEqual(["securityReview"]);
  });
});
