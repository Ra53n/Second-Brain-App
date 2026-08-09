// reducer.test.ts — чистое ядро execution loop: скриптованные события, без моков.

import { describe, it, expect } from "vitest";
import { apply } from "../src/fsm/reducer.js";
import type { CorrectnessVerdict, Finding, PhaseEvent, RunContext } from "../src/fsm/types.js";

function ctx(over: Partial<RunContext> = {}): RunContext {
  return {
    id: "r1",
    taskPrompt: "сделай",
    state: "generating",
    status: "running",
    round: 1,
    maxRounds: 4,
    result: "",
    correctness: null,
    findings: [],
    warnings: [],
    feedback: "",
    outcome: null,
    errorText: null,
    pwned: false,
    costUsd: 0,
    startedAt: "",
    ...over,
  };
}

const gen = (result: string | null, gatewayBlocked = false): PhaseEvent => ({ kind: "generated", result, gatewayBlocked });
const ver = (verdict: CorrectnessVerdict | null, gatewayBlocked = false): PhaseEvent => ({ kind: "verified", verdict, gatewayBlocked });
const rev = (findings: Finding[] | null, gatewayBlocked = false): PhaseEvent => ({ kind: "reviewed", findings, gatewayBlocked });

describe("reducer — happy path", () => {
  it("генерация → корректно → security чисто → done", () => {
    let o = apply(ctx(), gen("ответ"));
    expect(o.ctx.state).toBe("verifying");
    expect(o.ctx.result).toBe("ответ");

    o = apply(o.ctx, ver({ correct: true, issues: [] }));
    expect(o.ctx.state).toBe("securityReview");

    o = apply(o.ctx, rev([]));
    expect(o.ctx.state).toBe("done");
    expect(o.ctx.status).toBe("finished");
    expect(o.ctx.outcome).toBe("done");
    expect(o.isTerminal).toBe(true);
  });
});

describe("reducer — проверка корректности", () => {
  it("не корректно → возврат на генерацию с замечаниями", () => {
    const o = apply(ctx({ state: "verifying", round: 1 }), ver({ correct: false, issues: ["не отвечает на вопрос"] }));
    expect(o.ctx.state).toBe("generating");
    expect(o.ctx.round).toBe(2);
    expect(o.ctx.feedback).toContain("не отвечает на вопрос");
  });

  it("исчерпание кругов при некорректности → stopped-limit", () => {
    const o = apply(ctx({ state: "verifying", round: 4 }), ver({ correct: false, issues: ["x"] }));
    expect(o.ctx.outcome).toBe("stopped-limit");
    expect(o.isTerminal).toBe(true);
  });

  it("непарсящийся вердикт корректности → verdict-unparsed", () => {
    const o = apply(ctx({ state: "verifying" }), ver(null));
    expect(o.ctx.outcome).toBe("verdict-unparsed");
  });
});

describe("reducer — security review", () => {
  it("Critical/High → возврат на генерацию с фидбеком", () => {
    const o = apply(ctx({ state: "securityReview", round: 1 }), rev([{ severity: "high", issue: "утечка токена" }]));
    expect(o.ctx.state).toBe("generating");
    expect(o.ctx.round).toBe(2);
    expect(o.ctx.feedback).toContain("утечка токена");
  });

  it("только Medium/Low → warning и done", () => {
    const o = apply(ctx({ state: "securityReview" }), rev([{ severity: "medium", issue: "нет валидации" }]));
    expect(o.ctx.state).toBe("done");
    expect(o.ctx.outcome).toBe("done");
    expect(o.ctx.warnings).toHaveLength(1);
    expect(o.ctx.warnings[0]).toContain("medium");
  });

  it("исчерпание кругов с оставшимся critical → stopped-limit", () => {
    const o = apply(ctx({ state: "securityReview", round: 4 }), rev([{ severity: "critical", issue: "RCE" }]));
    expect(o.ctx.outcome).toBe("stopped-limit");
  });

  it("gateway заблокировал → gateway-blocked", () => {
    expect(apply(ctx({ state: "securityReview" }), rev(null, true)).ctx.outcome).toBe("gateway-blocked");
  });
});

describe("reducer — генерация без результата", () => {
  it("пустой результат → новый круг", () => {
    const o = apply(ctx(), gen(""));
    expect(o.ctx.state).toBe("generating");
    expect(o.ctx.round).toBe(2);
  });
  it("gateway заблокировал генерацию → gateway-blocked", () => {
    expect(apply(ctx(), gen(null, true)).ctx.outcome).toBe("gateway-blocked");
  });
  it("пустой результат на последнем круге → stopped-limit", () => {
    expect(apply(ctx({ round: 4 }), gen("")).ctx.outcome).toBe("stopped-limit");
  });
});
