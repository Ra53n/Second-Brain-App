// reducer.test.ts — чистое ядро FSM: скриптованные события фаз, ни одного мока.
// Порт AgentReducerTests.

import { describe, it, expect } from "vitest";
import { apply } from "../src/fsm/reducer.js";
import type { Finding, PhaseEvent, RunContext } from "../src/fsm/types.js";

function ctx(over: Partial<RunContext> = {}): RunContext {
  return {
    id: "r1",
    taskId: "t1",
    taskTitle: "Задача",
    taskPrompt: "сделай",
    secure: true,
    state: "generating",
    status: "running",
    round: 1,
    maxRounds: 4,
    code: "",
    buildErrors: "",
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

const gen = (code: string | null, truncated = false, gatewayBlocked = false): PhaseEvent => ({
  kind: "generated",
  code,
  truncated,
  gatewayBlocked,
});
const tested = (ok: boolean, errors = ""): PhaseEvent => ({ kind: "tested", ok, errors });
const reviewed = (findings: Finding[] | null, gatewayBlocked = false): PhaseEvent => ({
  kind: "reviewed",
  findings,
  gatewayBlocked,
});

describe("reducer — happy path", () => {
  it("генерация → тест → чистый ревью → коммит → done", () => {
    let c = ctx();
    let o = apply(c, gen("console.log(1)\n"));
    expect(o.ctx.state).toBe("testing");
    expect(o.ctx.code).toContain("console.log");

    o = apply(o.ctx, tested(true));
    expect(o.ctx.state).toBe("securityReview");

    o = apply(o.ctx, reviewed([]));
    expect(o.ctx.state).toBe("committing");

    o = apply(o.ctx, { kind: "committed" });
    expect(o.ctx.state).toBe("done");
    expect(o.ctx.status).toBe("finished");
    expect(o.ctx.outcome).toBe("committed");
    expect(o.isTerminal).toBe(true);
  });
});

describe("reducer — сборка", () => {
  it("падение сборки возвращает на генерацию с ростом круга", () => {
    const c = ctx({ state: "testing", code: "bad(" });
    const o = apply(c, tested(false, "SyntaxError: unexpected end"));
    expect(o.ctx.state).toBe("generating");
    expect(o.ctx.round).toBe(2);
    expect(o.ctx.feedback).toContain("node --check");
  });

  it("исчерпание кругов на несборке → stopped-limit", () => {
    const c = ctx({ state: "testing", round: 4 });
    const o = apply(c, tested(false, "err"));
    expect(o.ctx.outcome).toBe("stopped-limit");
    expect(o.isTerminal).toBe(true);
  });
});

describe("reducer — security review", () => {
  it("Critical/High возвращают на генерацию с фидбеком по строке", () => {
    const c = ctx({ state: "securityReview", round: 1 });
    const o = apply(c, reviewed([{ severity: "high", line: 42, issue: "SQL injection" }]));
    expect(o.ctx.state).toBe("generating");
    expect(o.ctx.round).toBe(2);
    expect(o.ctx.feedback).toContain("SQL injection");
    expect(o.ctx.feedback).toContain("42");
  });

  it("только Medium/Low → warning в контекст и коммит", () => {
    const c = ctx({ state: "securityReview" });
    const o = apply(c, reviewed([{ severity: "medium", line: 3, issue: "нет валидации" }]));
    expect(o.ctx.state).toBe("committing");
    expect(o.ctx.warnings).toHaveLength(1);
    expect(o.ctx.warnings[0]).toContain("medium");
  });

  it("исчерпание кругов с оставшимся high → stopped-limit, коммита нет", () => {
    const c = ctx({ state: "securityReview", round: 4 });
    const o = apply(c, reviewed([{ severity: "critical", line: 1, issue: "RCE" }]));
    expect(o.ctx.outcome).toBe("stopped-limit");
    expect(o.ctx.state).toBe("done");
  });

  it("непарсящийся вердикт → verdict-unparsed", () => {
    const c = ctx({ state: "securityReview" });
    const o = apply(c, reviewed(null));
    expect(o.ctx.outcome).toBe("verdict-unparsed");
    expect(o.isTerminal).toBe(true);
  });

  it("gateway заблокировал ревью → gateway-blocked", () => {
    const c = ctx({ state: "securityReview" });
    const o = apply(c, reviewed(null, true));
    expect(o.ctx.outcome).toBe("gateway-blocked");
  });
});

describe("reducer — генерация без кода", () => {
  it("обрыв по maxTokens → просим компактно, круг растёт", () => {
    const c = ctx({ state: "generating" });
    const o = apply(c, gen(null, true));
    expect(o.ctx.state).toBe("generating");
    expect(o.ctx.round).toBe(2);
    expect(o.ctx.feedback).toContain("компактно");
  });

  it("нет блока кода → просим блок", () => {
    const c = ctx({ state: "generating" });
    const o = apply(c, gen(null, false));
    expect(o.ctx.feedback).toContain("```js");
  });

  it("gateway заблокировал генерацию → gateway-blocked", () => {
    const c = ctx({ state: "generating" });
    const o = apply(c, gen(null, false, true));
    expect(o.ctx.outcome).toBe("gateway-blocked");
  });

  it("нет кода на последнем круге → stopped-limit", () => {
    const c = ctx({ state: "generating", round: 4 });
    const o = apply(c, gen(null, true));
    expect(o.ctx.outcome).toBe("stopped-limit");
  });
});
