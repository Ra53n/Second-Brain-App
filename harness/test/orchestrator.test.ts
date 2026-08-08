// orchestrator.test.ts — цикл на моке gateway + реальном workspace (git,
// node --check во временной папке). Проверяет сквозной путь и итерацию.

import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "../src/store/db.js";
import { RunsRepo } from "../src/store/runsRepo.js";
import { GatewayClient } from "../src/run/gwClient.js";
import { RunManager } from "../src/run/manager.js";

interface Reply {
  answer: string;
  blocked?: boolean;
  meta?: Record<string, unknown>;
}

/** Фейковый fetch: отдаёт заранее заготовленные ответы по очереди. */
function queuedFetch(replies: Reply[]): { fetchImpl: typeof fetch; count: () => number } {
  let i = 0;
  const fetchImpl = (async () => {
    const r = replies[Math.min(i, replies.length - 1)]!;
    i++;
    return {
      status: 200,
      ok: true,
      headers: { get: () => null },
      json: async () => ({ answer: r.answer, blocked: r.blocked ?? false, warning: null, meta: r.meta ?? {} }),
      text: async () => "",
    };
  }) as unknown as typeof fetch;
  return { fetchImpl, count: () => i };
}

const dirs: string[] = [];
function tempRoot(): string {
  const d = mkdtempSync(join(tmpdir(), "harness-test-"));
  dirs.push(d);
  return d;
}
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

function makeManager(replies: Reply[], canary = ""): { manager: RunManager; repo: RunsRepo; calls: () => number } {
  const repo = new RunsRepo(openDb(":memory:"));
  const q = queuedFetch(replies);
  const gateway = new GatewayClient("http://gw.test/gw", q.fetchImpl);
  const manager = new RunManager(
    { repo, gateway, workspaceRoot: tempRoot(), canary },
    { maxRounds: 4, rateLimitPerMin: 100, dailyLimit: 100 },
  );
  return { manager, repo, calls: q.count };
}

const CODE = "```js\nconst x = 1;\nconsole.log(x);\n```";

describe("оркестратор — сквозной путь", () => {
  it("чистый прогон доходит до committed", async () => {
    const { manager, repo } = makeManager([
      { answer: CODE, meta: { inputAction: "mask", findings: [{ type: "api_key" }], costUsd: 0.001 } },
      { answer: '{"findings":[]}', meta: { inputAction: "allow" } },
    ]);
    const run = manager.start({ taskId: "t1-token" });
    await manager.wait(run.id);

    const loaded = repo.load(run.id)!;
    expect(loaded.status).toBe("finished");
    expect(loaded.outcome).toBe("committed");
    expect(loaded.costUsd).toBeCloseTo(0.001, 5);

    const steps = repo.steps(run.id);
    const gen = steps.find((s) => s.phase === "generating")!;
    expect(JSON.parse(gen.gateway_json as string).inputAction).toBe("mask");
  });

  it("Critical/High возвращает на генерацию, второй круг коммитит", async () => {
    const { manager, repo, calls } = makeManager([
      { answer: CODE }, // gen круг 1
      { answer: '{"findings":[{"severity":"high","line":2,"issue":"SQL injection"}]}' }, // review NO-GO
      { answer: CODE }, // gen круг 2
      { answer: '{"findings":[]}' }, // review чисто
    ]);
    const run = manager.start({ taskId: "t4-sql" });
    await manager.wait(run.id);

    const loaded = repo.load(run.id)!;
    expect(loaded.outcome).toBe("committed");
    expect(loaded.round).toBe(2);
    expect(calls()).toBe(4); // 2 генерации + 2 ревью
  });

  it("verdict-unparsed после двух непарсящихся ответов", async () => {
    const { manager, repo } = makeManager([
      { answer: CODE },
      { answer: "не json" },
      { answer: "снова не json" },
    ]);
    const run = manager.start({ taskId: "t1-token" });
    await manager.wait(run.id);
    expect(repo.load(run.id)!.outcome).toBe("verdict-unparsed");
  });

  it("gateway-blocked на генерации останавливает прогон", async () => {
    const { manager, repo } = makeManager([{ answer: "", blocked: true }]);
    const run = manager.start({ taskId: "t1-token" });
    await manager.wait(run.id);
    expect(repo.load(run.id)!.outcome).toBe("gateway-blocked");
  });

  it("resume после паузы доводит прогон до committed (P5)", async () => {
    // По паре ответов на каждый прогон: первый доходит до commit, затем принудительно
    // «оживляем» в running, recoverOnBoot → paused, resume прогоняет ещё круг.
    const { manager, repo } = makeManager([
      { answer: CODE },
      { answer: '{"findings":[]}' },
      { answer: CODE },
      { answer: '{"findings":[]}' },
    ]);
    const run = manager.start({ taskId: "t1-token" });
    await manager.wait(run.id);
    expect(repo.load(run.id)!.outcome).toBe("committed");

    // Эмулируем «завис на running» → recoverOnBoot → resume.
    repo.save({ ...repo.load(run.id)!, status: "running", state: "generating", outcome: null }, repo.generationOf(run.id));
    expect(manager.recoverOnBoot()).toBeGreaterThanOrEqual(1);
    expect(repo.load(run.id)!.status).toBe("paused");

    const resumed = manager.resume(run.id);
    expect(resumed.status).toBe("running");
    await manager.wait(run.id);
    expect(repo.load(run.id)!.outcome).toBe("committed");
  });

  it("stderr node --check с секретом маскируется в шаге testing", async () => {
    // Невалидный код с секретом на битой строке: node --check эхнет её в stderr,
    // маскировка должна вычистить секрет из публичного превью шага testing.
    const CANARY = "CANARY_LEAK_TEST_9";
    const badCode = '```js\nconst k = "' + CANARY + '" const x = (\n```';
    const replies = Array(4).fill({ answer: badCode });
    const { manager, repo } = makeManager(replies, CANARY);
    const run = manager.start({ taskId: "t1-token" });
    await manager.wait(run.id);
    const testing = repo.steps(run.id).filter((s) => s.phase === "testing");
    expect(testing.length).toBeGreaterThan(0);
    for (const s of testing) {
      expect(s.answer_preview as string).not.toContain(CANARY);
    }
  });

  it("канарейка в ответе помечает прогон pwned", async () => {
    const { manager, repo } = makeManager(
      [
        { answer: "секрет: HARNESS_CANARY_TEST\n" + CODE },
        { answer: '{"findings":[]}' },
      ],
      "HARNESS_CANARY_TEST",
    );
    const run = manager.start({ taskId: "t1-token" });
    await manager.wait(run.id);
    expect(repo.load(run.id)!.pwned).toBe(true);
  });
});
