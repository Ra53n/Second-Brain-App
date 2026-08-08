// migration.test.ts — стор: снисходительный декодер, «значение из будущего»,
// running → paused на старте, защита поколением.

import { describe, it, expect } from "vitest";
import { openDb } from "../src/store/db.js";
import { RunsRepo } from "../src/store/runsRepo.js";
import type { RunContext } from "../src/fsm/types.js";

function makeRepo(): RunsRepo {
  return new RunsRepo(openDb(":memory:"));
}

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
    startedAt: "2026-01-01T00:00:00Z",
    ...over,
  };
}

describe("RunsRepo — round-trip и декодер", () => {
  it("insert + load сохраняет контекст", () => {
    const repo = makeRepo();
    repo.insert(ctx({ round: 3, warnings: ["w1"] }));
    const loaded = repo.load("r1");
    expect(loaded?.round).toBe(3);
    expect(loaded?.warnings).toEqual(["w1"]);
  });

  it("битый JSON контекста → безопасные дефолты", () => {
    const db = openDb(":memory:");
    db.prepare(
      "INSERT INTO runs (id, created_at, updated_at, ctx_json) VALUES ('bad','x','x','{не json')",
    ).run();
    const loaded = new RunsRepo(db).load("bad");
    expect(loaded?.state).toBe("generating");
    expect(loaded?.status).toBe("paused");
    expect(loaded?.maxRounds).toBe(4);
  });

  it("неизвестный enum «из будущего» → безопасное значение", () => {
    const db = openDb(":memory:");
    db.prepare("INSERT INTO runs (id, created_at, updated_at, ctx_json) VALUES ('f','x','x',?)").run(
      JSON.stringify({ id: "f", state: "quantum", status: "warp" }),
    );
    const loaded = new RunsRepo(db).load("f");
    expect(loaded?.state).toBe("generating");
    expect(loaded?.status).toBe("paused");
  });
});

describe("RunsRepo — crash-safety", () => {
  it("pauseRunning переводит зависшие running → paused", () => {
    const repo = makeRepo();
    repo.insert(ctx({ id: "r1", status: "running" }));
    repo.insert(ctx({ id: "r2", status: "running" }));
    expect(repo.pauseRunning()).toBe(2);
    expect(repo.load("r1")?.status).toBe("paused");
  });

  it("save под устаревшим поколением возвращает false и не пишет", () => {
    const repo = makeRepo();
    repo.insert(ctx());
    const current = repo.bumpGeneration("r1"); // → 1
    expect(repo.save(ctx({ round: 9 }), current - 1)).toBe(false); // старое поколение 0
    expect(repo.load("r1")?.round).toBe(1);
    expect(repo.save(ctx({ round: 9 }), current)).toBe(true);
    expect(repo.load("r1")?.round).toBe(9);
  });
});
