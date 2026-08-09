// transitions.test.ts — таблица переходов FSM: каждая пара против эталона.

import { describe, it, expect } from "vitest";
import { ALL_STATES, allows, TRANSITIONS, type RunState } from "../src/fsm/types.js";

const expected: Record<RunState, Set<RunState>> = {
  generating: new Set<RunState>(["verifying"]),
  verifying: new Set<RunState>(["securityReview", "generating"]),
  securityReview: new Set<RunState>(["done", "generating"]),
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

  it("в done можно попасть только из securityReview", () => {
    expect(ALL_STATES.filter((s) => allows(s, "done"))).toEqual(["securityReview"]);
  });

  it("на генерацию возвращают и verifying, и securityReview", () => {
    expect(allows("verifying", "generating")).toBe(true);
    expect(allows("securityReview", "generating")).toBe(true);
  });
});
