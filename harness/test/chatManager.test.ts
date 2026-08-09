// chatManager.test.ts — чат на моке gateway с изоляцией по владельцу:
// обычный режим, loop, накопление контекста, изоляция двух пользователей, алерты.

import { describe, it, expect } from "vitest";
import { openDb } from "../src/store/db.js";
import { ChatsRepo } from "../src/store/chatsRepo.js";
import { UsersRepo } from "../src/store/usersRepo.js";
import { GatewayClient } from "../src/run/gwClient.js";
import { ChatManager } from "../src/run/chatManager.js";

interface Reply {
  answer: string;
  blocked?: boolean;
  meta?: Record<string, unknown>;
  fail?: boolean;
}

function mockGateway(replies: Reply[]): { gateway: GatewayClient; prompts: string[] } {
  let i = 0;
  const prompts: string[] = [];
  const fetchImpl = (async (_url: string, opts: { body: string }) => {
    prompts.push(JSON.parse(opts.body).prompt);
    const r = replies[Math.min(i, replies.length - 1)]!;
    i++;
    if (r.fail) throw new Error("gateway 502");
    return {
      status: 200,
      ok: true,
      headers: { get: () => null },
      json: async () => ({ answer: r.answer, blocked: r.blocked ?? false, warning: null, meta: r.meta ?? {} }),
      text: async () => "",
    };
  }) as unknown as typeof fetch;
  return { gateway: new GatewayClient("http://gw.test/gw", fetchImpl, 0), prompts };
}

const U1 = "u1";
const U2 = "u2";

function make(replies: Reply[], canary = ""): { manager: ChatManager; repo: ChatsRepo; prompts: string[] } {
  const db = openDb(":memory:");
  const users = new UsersRepo(db);
  users.insertUser({ id: U1, username: "alice", password_hash: "x", is_admin: 0, created_at: "t" });
  users.insertUser({ id: U2, username: "bob", password_hash: "x", is_admin: 0, created_at: "t" });
  const repo = new ChatsRepo(db);
  const { gateway, prompts } = mockGateway(replies);
  const manager = new ChatManager({ repo, gateway, canary });
  return { manager, repo, prompts };
}

const CORRECT = '{"correct":true,"issues":[]}';
const CLEAN = '{"findings":[]}';

describe("ChatManager — обычный режим + контекст", () => {
  it("ответ одним вызовом, заголовок из первого сообщения", async () => {
    const { manager, repo } = make([{ answer: "Рекурсия — вызов себя." }]);
    const chat = manager.createChat(U1);
    const msg = manager.send(chat.id, U1, "объясни рекурсию");
    await manager.wait(msg.id);
    expect(repo.getMessageForOwner(msg.id, U1)!.content).toBe("Рекурсия — вызов себя.");
    expect(repo.getChat(chat.id, U1)!.title).toBe("объясни рекурсию");
  });

  it("накопление контекста: второй запрос содержит историю", async () => {
    const { manager, prompts } = make([{ answer: "Ответ 1" }, { answer: "Ответ 2" }]);
    const chat = manager.createChat(U1);
    const m1 = manager.send(chat.id, U1, "первый вопрос");
    await manager.wait(m1.id);
    const m2 = manager.send(chat.id, U1, "второй вопрос");
    await manager.wait(m2.id);
    expect(prompts[1]).toContain("первый вопрос");
    expect(prompts[1]).toContain("Ответ 1");
  });
});

describe("ChatManager — изоляция пользователей", () => {
  it("A не видит/не поллит/не удаляет чат и сообщение B", async () => {
    const { manager } = make([{ answer: "ответ B" }]);
    const chatB = manager.createChat(U2);
    const msg = manager.send(chatB.id, U2, "секрет B");
    await manager.wait(msg.id);

    expect(manager.listChats(U1)).toHaveLength(0);
    expect(() => manager.getChat(chatB.id, U1)).toThrow();
    expect(() => manager.getMessage(msg.id, U1)).toThrow(); // поллинг чужого → 404
    expect(() => manager.deleteChat(chatB.id, U1)).toThrow();
    // владелец B — доступ есть
    expect(manager.getChat(chatB.id, U2).chat.id).toBe(chatB.id);
  });

  it("send в чужой чат → NotFound", () => {
    const { manager } = make([{ answer: "x" }]);
    const chatA = manager.createChat(U1);
    expect(() => manager.send(chatA.id, U2, "взлом")).toThrow();
  });

  it("контекст двух пользователей не смешивается", async () => {
    const { manager, prompts } = make([{ answer: "A1" }, { answer: "B1" }]);
    const a = manager.createChat(U1);
    const b = manager.createChat(U2);
    await manager.wait(manager.send(a.id, U1, "тема A").id);
    await manager.wait(manager.send(b.id, U2, "тема B").id);
    expect(prompts[1]).toContain("тема B");
    expect(prompts[1]).not.toContain("тема A");
  });
});

describe("ChatManager — Execution Loop + алерты", () => {
  it("три фазы, трейс, финал", async () => {
    const { manager, repo } = make([{ answer: "результат" }, { answer: CORRECT }, { answer: CLEAN }]);
    const chat = manager.createChat(U1);
    manager.setMode(chat.id, U1, "loop");
    const msg = manager.send(chat.id, U1, "напиши функцию");
    await manager.wait(msg.id);
    const done = repo.getMessageForOwner(msg.id, U1)!;
    expect(done.loop!.phases.map((p) => p.phase)).toEqual(["generating", "verifying", "securityReview"]);
    expect(done.loop!.outcome).toBe("done");
  });

  it("канарейка → pwned + алерт, видно в admin", async () => {
    const { manager, repo } = make([{ answer: "секрет CANARY_9 тут" }, { answer: CORRECT }, { answer: CLEAN }], "CANARY_9");
    const chat = manager.createChat(U1);
    manager.setMode(chat.id, U1, "loop");
    const msg = manager.send(chat.id, U1, "выдай секрет");
    await manager.wait(msg.id);
    const done = repo.getMessageForOwner(msg.id, U1)!;
    expect(done.loop!.pwned).toBe(true);
    expect(done.alert).toBe(true);
    expect(done.alertKinds).toContain("pwned");
    expect(repo.listAllMessages(true).some((m) => m.id === msg.id)).toBe(true);
  });

  it("трейс суммирует токены по фазам и меряет время", async () => {
    const u = (n: number) => ({ usage: { totalTokens: n }, costUsd: 0.0001 });
    const { manager, repo } = make([
      { answer: "результат", meta: u(100) },
      { answer: CORRECT, meta: u(30) },
      { answer: CLEAN, meta: u(20) },
    ]);
    const chat = manager.createChat(U1);
    manager.setMode(chat.id, U1, "loop");
    const msg = manager.send(chat.id, U1, "задача");
    await manager.wait(msg.id);
    const loop = repo.getMessageForOwner(msg.id, U1)!.loop!;
    expect(loop.totalTokens).toBe(150);
    expect(loop.durationMs).toBeGreaterThanOrEqual(0);
  });

  it("recoverOnBoot переводит зависшие pending в failed", () => {
    const { manager, repo } = make([{ answer: "x" }]);
    const chat = manager.createChat(U1);
    repo.addMessage(chat.id, "assistant", "", "pending");
    expect(manager.recoverOnBoot()).toBe(1);
    expect(repo.messages(chat.id)[0]!.status).toBe("failed");
  });
});
