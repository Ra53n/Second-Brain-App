// chatsRepo.test.ts — персистентность + изоляция по владельцу, alert-колонки,
// admin-выборки, снисходительный декод, makeTitle, computeAlerts.

import { describe, it, expect, afterEach } from "vitest";
import Database from "better-sqlite3";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "../src/store/db.js";
import { ChatsRepo } from "../src/store/chatsRepo.js";
import { UsersRepo } from "../src/store/usersRepo.js";
import { makeTitle, computeAlerts, type LoopTrace } from "../src/domain/chat.js";

function fresh(): { repo: ChatsRepo; users: UsersRepo; a: string; b: string } {
  const db = openDb(":memory:");
  const users = new UsersRepo(db);
  const mk = (id: string, name: string) =>
    users.insertUser({ id, username: name, password_hash: "x", is_admin: 0, created_at: "t" });
  mk("ua", "alice");
  mk("ub", "bob");
  return { repo: new ChatsRepo(db), users, a: "ua", b: "ub" };
}

describe("makeTitle", () => {
  it("первая строка, ≤40 символов", () => {
    expect(makeTitle("привет\nвторая")).toBe("привет");
    expect(makeTitle("")).toBe("Новый чат");
    expect(makeTitle("x".repeat(50))).toBe("x".repeat(40) + "…");
  });
});

describe("ChatsRepo — изоляция по владельцу", () => {
  it("listChats возвращает только свои", () => {
    const { repo, a, b } = fresh();
    repo.createChat(a);
    repo.createChat(a);
    repo.createChat(b);
    expect(repo.listChats(a)).toHaveLength(2);
    expect(repo.listChats(b)).toHaveLength(1);
  });

  it("getChat чужого → null (не раскрываем существование)", () => {
    const { repo, a, b } = fresh();
    const c = repo.createChat(a);
    expect(repo.getChat(c.id, a)).not.toBeNull();
    expect(repo.getChat(c.id, b)).toBeNull();
  });

  it("deleteChat чужого → false, чат жив", () => {
    const { repo, a, b } = fresh();
    const c = repo.createChat(a);
    expect(repo.deleteChat(c.id, b)).toBe(false);
    expect(repo.getChat(c.id, a)).not.toBeNull();
    expect(repo.deleteChat(c.id, a)).toBe(true);
  });

  it("rename/setMode чужого — не действуют", () => {
    const { repo, a, b } = fresh();
    const c = repo.createChat(a);
    repo.rename(c.id, b, "взлом");
    repo.setMode(c.id, b, "loop");
    const mine = repo.getChat(c.id, a)!;
    expect(mine.title).toBe("Новый чат");
    expect(mine.mode).toBe("normal");
  });

  it("getMessageForOwner: чужое сообщение → null (фикс бага поллинга)", () => {
    const { repo, a, b } = fresh();
    const c = repo.createChat(a);
    const m = repo.addMessage(c.id, "assistant", "секрет A", "done");
    expect(repo.getMessageForOwner(m.id, a)!.content).toBe("секрет A");
    expect(repo.getMessageForOwner(m.id, b)).toBeNull();
  });

  it("удаление чата каскадом чистит сообщения (FK ON)", () => {
    const { repo, a } = fresh();
    const c = repo.createChat(a);
    repo.addMessage(c.id, "user", "привет", "done");
    repo.deleteChat(c.id, a);
    expect(repo.messages(c.id)).toHaveLength(0);
  });
});

describe("ChatsRepo — сообщения, alert, admin", () => {
  it("seq растёт, порядок сохраняется", () => {
    const { repo, a } = fresh();
    const c = repo.createChat(a);
    repo.addMessage(c.id, "user", "1", "done");
    repo.addMessage(c.id, "assistant", "2", "done");
    expect(repo.messages(c.id).map((m) => m.seq)).toEqual([0, 1]);
  });

  it("updateMessage пишет alert/alertKinds, admin фильтрует по алертам", () => {
    const { repo, a } = fresh();
    const c = repo.createChat(a);
    const m1 = repo.addMessage(c.id, "assistant", "", "pending");
    const g1 = repo.bumpMessageGeneration(m1.id);
    repo.updateMessage(m1.id, g1, { content: "ок", status: "done", alert: false, alertKinds: [] });
    const m2 = repo.addMessage(c.id, "assistant", "", "pending");
    const g2 = repo.bumpMessageGeneration(m2.id);
    repo.updateMessage(m2.id, g2, { content: "утёк", status: "done", alert: true, alertKinds: ["pwned"] });

    expect(repo.listAllMessages(false)).toHaveLength(2);
    const alerts = repo.listAllMessages(true);
    expect(alerts).toHaveLength(1);
    expect(alerts[0]!.alertKinds).toEqual(["pwned"]);
    expect(alerts[0]!.username).toBe("alice");
  });

  it("adminStats считает по всем", () => {
    const { repo, a, b } = fresh();
    repo.createChat(a);
    repo.createChat(b);
    const s = repo.adminStats();
    expect(s.users).toBe(2);
    expect(s.chats).toBe(2);
  });

  it("updateMessage под устаревшим поколением не проходит", () => {
    const { repo, a } = fresh();
    const c = repo.createChat(a);
    const m = repo.addMessage(c.id, "assistant", "", "pending");
    const g = repo.bumpMessageGeneration(m.id);
    expect(repo.updateMessage(m.id, g, { content: "ок", status: "done" })).toBe(true);
    expect(repo.updateMessage(m.id, g - 1, { content: "поздно" })).toBe(false);
  });
});

describe("миграция схемы v1 (задача 105) → v2 (авторизация)", () => {
  const dirs: string[] = [];
  afterEach(() => {
    for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
  });

  it("существующая БД задачи 105 (user_version=1) обновляется до v2", () => {
    const dir = mkdtempSync(join(tmpdir(), "harness-mig-"));
    dirs.push(dir);
    const path = join(dir, "old.db");
    // Ставим СТАРУЮ v1-схему задачи 105 и user_version=1.
    const raw = new Database(path);
    raw.exec(`
      CREATE TABLE chats (id TEXT PRIMARY KEY, title TEXT, mode TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE messages (id TEXT PRIMARY KEY, chat_id TEXT, seq INTEGER, role TEXT, content TEXT, status TEXT, generation INTEGER, error_text TEXT, loop_json TEXT, created_at TEXT);
    `);
    raw.exec("INSERT INTO chats (id,title,mode,created_at,updated_at) VALUES ('c1','old','normal','t','t')");
    raw.pragma("user_version = 1");
    raw.close();

    // openDb должен накатить v2.
    const db = openDb(path);
    expect(db.pragma("user_version", { simple: true })).toBe(2);
    const tables = (db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all() as Array<{ name: string }>).map((r) => r.name);
    expect(tables).toContain("users");
    expect(tables).toContain("user_sessions");
    const chatCols = (db.prepare("PRAGMA table_info(chats)").all() as Array<{ name: string }>).map((c) => c.name);
    expect(chatCols).toContain("user_id");
    const msgCols = (db.prepare("PRAGMA table_info(messages)").all() as Array<{ name: string }>).map((c) => c.name);
    expect(msgCols).toContain("alert");
    db.close();
  });
});

describe("decodeKinds (снисходительный)", () => {
  it("битый alert_kinds → [] (не падает)", () => {
    const db = openDb(":memory:");
    new UsersRepo(db).insertUser({ id: "u", username: "u", password_hash: "x", is_admin: 0, created_at: "t" });
    db.prepare("INSERT INTO chats (id,user_id,title,mode,created_at,updated_at) VALUES ('c','u','t','normal','t','t')").run();
    db.prepare("INSERT INTO messages (id,chat_id,seq,role,content,status,generation,created_at,alert_kinds) VALUES ('m','c',0,'assistant','x','done',0,'t','{битый')").run();
    expect(new ChatsRepo(db).getMessage("m")!.alertKinds).toEqual([]);
  });
});

describe("computeAlerts", () => {
  const loop = (over: Partial<LoopTrace>): LoopTrace => ({ rounds: 1, outcome: null, pwned: false, costUsd: 0, phases: [], ...over });
  it("pwned → алерт", () => {
    expect(computeAlerts(loop({ pwned: true }), "x", "done").kinds).toContain("pwned");
  });
  it("critical/high finding → security-high", () => {
    const l = loop({ phases: [{ phase: "securityReview", round: 1, display: "", findings: [{ severity: "high", issue: "x" }], correctnessIssues: [], gateway: { inputAction: null, findingTypes: [], outputVerdict: null, blocked: false }, pwned: false }] });
    expect(computeAlerts(l, "x", "done").kinds).toContain("security-high");
  });
  it("gateway inputAction!=allow → gateway-intercept", () => {
    const l = loop({ phases: [{ phase: "generating", round: 1, display: "", findings: [], correctnessIssues: [], gateway: { inputAction: "mask", findingTypes: ["email"], outputVerdict: null, blocked: false }, pwned: false }] });
    expect(computeAlerts(l, "x", "done").kinds).toContain("gateway-intercept");
  });
  it("отказ модели → refusal", () => {
    expect(computeAlerts(null, "Не могу выполнить этот запрос.", "done").kinds).toContain("refusal");
  });
  it("failed статус → failed", () => {
    expect(computeAlerts(null, "", "failed").alert).toBe(true);
  });
  it("чистый ответ → без алерта", () => {
    expect(computeAlerts(loop({}), "обычный ответ", "done").alert).toBe(false);
  });
});
