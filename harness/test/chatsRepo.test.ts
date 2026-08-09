// chatsRepo.test.ts — персистентность чатов/сообщений: CRUD, seq, изоляция,
// снисходительный декод loop_json, makeTitle.

import { describe, it, expect } from "vitest";
import { openDb } from "../src/store/db.js";
import { ChatsRepo } from "../src/store/chatsRepo.js";
import { makeTitle } from "../src/domain/chat.js";

function repo(): ChatsRepo {
  return new ChatsRepo(openDb(":memory:"));
}

describe("makeTitle", () => {
  it("первая строка, ≤40 символов", () => {
    expect(makeTitle("привет\nвторая строка")).toBe("привет");
    expect(makeTitle("")).toBe("Новый чат");
    expect(makeTitle("x".repeat(50))).toBe("x".repeat(40) + "…");
  });
});

describe("ChatsRepo — чаты", () => {
  it("создание, список, переименование, режим, удаление", () => {
    const r = repo();
    const c = r.createChat();
    expect(r.listChats()).toHaveLength(1);
    r.rename(c.id, "Мой чат");
    expect(r.getChat(c.id)!.title).toBe("Мой чат");
    r.rename(c.id, "   "); // пустой игнорируется
    expect(r.getChat(c.id)!.title).toBe("Мой чат");
    r.setMode(c.id, "loop");
    expect(r.getChat(c.id)!.mode).toBe("loop");
    r.deleteChat(c.id);
    expect(r.listChats()).toHaveLength(0);
  });

  it("удаление чата убирает его сообщения", () => {
    const r = repo();
    const c = r.createChat();
    r.addMessage(c.id, "user", "привет", "done");
    r.deleteChat(c.id);
    expect(r.messages(c.id)).toHaveLength(0);
  });
});

describe("ChatsRepo — сообщения", () => {
  it("seq растёт, порядок сохраняется", () => {
    const r = repo();
    const c = r.createChat();
    r.addMessage(c.id, "user", "1", "done");
    r.addMessage(c.id, "assistant", "2", "done");
    r.addMessage(c.id, "user", "3", "done");
    expect(r.messages(c.id).map((m) => m.seq)).toEqual([0, 1, 2]);
    expect(r.messages(c.id).map((m) => m.content)).toEqual(["1", "2", "3"]);
  });

  it("два чата не смешивают сообщения", () => {
    const r = repo();
    const a = r.createChat();
    const b = r.createChat();
    r.addMessage(a.id, "user", "в A", "done");
    r.addMessage(b.id, "user", "в B", "done");
    expect(r.messages(a.id).map((m) => m.content)).toEqual(["в A"]);
    expect(r.messages(b.id).map((m) => m.content)).toEqual(["в B"]);
  });

  it("updateMessage под верным поколением проходит, под устаревшим — нет", () => {
    const r = repo();
    const c = r.createChat();
    const m = r.addMessage(c.id, "assistant", "", "pending");
    const gen = r.bumpMessageGeneration(m.id);
    expect(r.updateMessage(m.id, gen, { content: "готово", status: "done" })).toBe(true);
    expect(r.getMessage(m.id)!.content).toBe("готово");
    expect(r.updateMessage(m.id, gen - 1, { content: "поздно" })).toBe(false);
    expect(r.getMessage(m.id)!.content).toBe("готово");
  });

  it("failPendingOnBoot переводит зависшие в failed", () => {
    const r = repo();
    const c = r.createChat();
    r.addMessage(c.id, "assistant", "", "pending");
    expect(r.failPendingOnBoot()).toBe(1);
    expect(r.messages(c.id)[0]!.status).toBe("failed");
  });

  it("битый loop_json → сообщение без трейса, не падает", () => {
    const db = openDb(":memory:");
    db.prepare("INSERT INTO chats (id,title,mode,created_at,updated_at) VALUES ('x','t','normal','a','a')").run();
    db.prepare(
      "INSERT INTO messages (id,chat_id,seq,role,content,status,generation,created_at,loop_json) VALUES ('m','x',0,'assistant','ответ','done',0,'a','{битый json')",
    ).run();
    const r = new ChatsRepo(db);
    expect(r.getMessage("m")!.loop).toBeNull();
    expect(r.getMessage("m")!.content).toBe("ответ");
  });
});
