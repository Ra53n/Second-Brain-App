// migration.test.ts — стор: снисходительный декодер, «значение из будущего»,
// running → paused на старте, защита поколением.

import { describe, it, expect, afterEach } from "vitest";
import Database from "better-sqlite3";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "../src/store/db.js";
import { RunsRepo } from "../src/store/runsRepo.js";
import type { RunContext } from "../src/fsm/types.js";

function makeRepo(): RunsRepo {
  return new RunsRepo(openDb(":memory:"));
}

function ctx(over: Partial<RunContext> = {}): RunContext {
  return {
    id: "r1",
    taskPrompt: "сделай",
    secure: true,
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

  it("старый ctx_json прошлой сборки (state=testing, поля code/taskId) декодируется", () => {
    const db = openDb(":memory:");
    db.prepare("INSERT INTO runs (id, created_at, updated_at, ctx_json) VALUES ('old','x','x',?)").run(
      JSON.stringify({ id: "old", taskId: "t1", taskTitle: "Задача", code: "x()", buildErrors: "err", state: "committing", status: "finished", round: 2 }),
    );
    const loaded = new RunsRepo(db).load("old");
    expect(loaded?.state).toBe("generating"); // committing → неизвестное → безопасный дефолт
    expect(loaded?.status).toBe("finished");
    expect(loaded?.round).toBe(2);
    expect(loaded?.result).toBe(""); // отсутствующее поле новой модели
  });
});

describe("миграция схемы v1 → v2", () => {
  const dirs: string[] = [];
  afterEach(() => {
    for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
  });

  it("существующая БД на v1 (steps без correctness_json) → v2 добавляет колонку, вставка шага проходит", () => {
    const dir = mkdtempSync(join(tmpdir(), "harness-mig-"));
    dirs.push(dir);
    const path = join(dir, "old.db");

    // Поднимаем СТАРУЮ v1-схему вручную и фиксируем user_version=1.
    const raw = new Database(path);
    raw.exec(`
      CREATE TABLE runs (id TEXT PRIMARY KEY, created_at TEXT, updated_at TEXT, task_id TEXT,
        task_title TEXT, state TEXT, status TEXT, outcome TEXT, round INTEGER, secure INTEGER,
        pwned INTEGER, cost_usd REAL, generation INTEGER, ctx_json TEXT);
      CREATE TABLE steps (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, created_at TEXT,
        round INTEGER, phase TEXT, display TEXT, prompt_preview TEXT, answer_preview TEXT,
        findings_json TEXT, gateway_json TEXT, egress_json TEXT, pwned INTEGER, cost_usd REAL);
    `);
    raw.pragma("user_version = 1");
    raw.close();

    // openDb должен накатить v2 (ALTER ADD COLUMN correctness_json).
    const db = openDb(path);
    expect(db.pragma("user_version", { simple: true })).toBe(2);
    const cols = (db.prepare("PRAGMA table_info(steps)").all() as Array<{ name: string }>).map((c) => c.name);
    expect(cols).toContain("correctness_json");

    // Вставка шага новой моделью не падает.
    const repo = new RunsRepo(db);
    expect(() =>
      repo.addStep({
        runId: "r", round: 1, phase: "generating", display: "d", promptPreview: "p", answerPreview: "a",
        findings: [], correctnessIssues: [{ severity: "info", issue: "x" }], gateway: {}, egress: [], pwned: false, costUsd: 0,
      }),
    ).not.toThrow();
    db.close();
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
