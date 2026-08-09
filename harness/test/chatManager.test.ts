// chatManager.test.ts — чат на моке gateway: обычный режим и Execution Loop,
// накопление контекста (история уходит в промпт), изоляция чатов, канарейка.

import { describe, it, expect } from "vitest";
import { openDb } from "../src/store/db.js";
import { ChatsRepo } from "../src/store/chatsRepo.js";
import { GatewayClient } from "../src/run/gwClient.js";
import { ChatManager } from "../src/run/chatManager.js";

interface Reply {
  answer: string;
  blocked?: boolean;
  meta?: Record<string, unknown>;
  fail?: boolean; // бросить сетевую ошибку на этом вызове
}

/** Мок fetch: отдаёт заготовленные ответы по очереди, пишет prompt'ы для ассертов. */
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
  // Без ретраев/пауз в тесте: retries=0.
  return { gateway: new GatewayClient("http://gw.test/gw", fetchImpl, 0), prompts };
}

function make(replies: Reply[], canary = ""): { manager: ChatManager; repo: ChatsRepo; prompts: string[] } {
  const repo = new ChatsRepo(openDb(":memory:"));
  const { gateway, prompts } = mockGateway(replies);
  const manager = new ChatManager({ repo, gateway, canary });
  return { manager, repo, prompts };
}

const CORRECT = '{"correct":true,"issues":[]}';
const CLEAN = '{"findings":[]}';

describe("ChatManager — обычный режим", () => {
  it("ответ одним вызовом, заголовок из первого сообщения", async () => {
    const { manager, repo } = make([{ answer: "Рекурсия — вызов себя.", meta: { inputAction: "mask", costUsd: 0.001 } }]);
    const chat = manager.createChat();
    const msg = manager.send(chat.id, "объясни рекурсию");
    await manager.wait(msg.id);

    const done = repo.getMessage(msg.id)!;
    expect(done.status).toBe("done");
    expect(done.content).toBe("Рекурсия — вызов себя.");
    expect(repo.getChat(chat.id)!.title).toBe("объясни рекурсию");
  });

  it("накопление контекста: второй запрос содержит историю", async () => {
    const { manager, repo, prompts } = make([{ answer: "Ответ 1" }, { answer: "Ответ 2" }]);
    const chat = manager.createChat();
    const m1 = manager.send(chat.id, "первый вопрос");
    await manager.wait(m1.id);
    const m2 = manager.send(chat.id, "второй вопрос");
    await manager.wait(m2.id);

    // Промпт второго вызова должен содержать историю (первый вопрос + первый ответ).
    expect(prompts[1]).toContain("первый вопрос");
    expect(prompts[1]).toContain("Ответ 1");
    expect(prompts[1]).toContain("второй вопрос");
  });

  it("два чата не смешивают контекст", async () => {
    const { manager, prompts } = make([{ answer: "A1" }, { answer: "B1" }]);
    const a = manager.createChat();
    const b = manager.createChat();
    const ma = manager.send(a.id, "тема A");
    await manager.wait(ma.id);
    const mb = manager.send(b.id, "тема B");
    await manager.wait(mb.id);
    expect(prompts[1]).toContain("тема B");
    expect(prompts[1]).not.toContain("тема A"); // история чата A не течёт в чат B
  });
});

describe("ChatManager — Execution Loop", () => {
  it("прогон трёх фаз, трейс + финальный результат", async () => {
    const { manager, repo } = make([{ answer: "результат" }, { answer: CORRECT }, { answer: CLEAN }]);
    const chat = manager.createChat();
    manager.setMode(chat.id, "loop");
    const msg = manager.send(chat.id, "напиши функцию");
    await manager.wait(msg.id);

    const done = repo.getMessage(msg.id)!;
    expect(done.status).toBe("done");
    expect(done.content).toBe("результат");
    expect(done.loop).not.toBeNull();
    expect(done.loop!.phases.map((p) => p.phase)).toEqual(["generating", "verifying", "securityReview"]);
    expect(done.loop!.outcome).toBe("done");
  });

  it("security Critical/High → возврат на генерацию (несколько кругов в трейсе)", async () => {
    const { manager, repo } = make([
      { answer: "небезопасно" },
      { answer: CORRECT },
      { answer: '{"findings":[{"severity":"high","issue":"хардкод ключа"}]}' },
      { answer: "исправлено" },
      { answer: CORRECT },
      { answer: CLEAN },
    ]);
    const chat = manager.createChat();
    manager.setMode(chat.id, "loop");
    const msg = manager.send(chat.id, "дай конфиг");
    await manager.wait(msg.id);

    const done = repo.getMessage(msg.id)!;
    expect(done.loop!.outcome).toBe("done");
    expect(done.loop!.rounds).toBe(2);
    const sec = done.loop!.phases.filter((p) => p.phase === "securityReview");
    expect(sec[0]!.findings[0]!.issue).toContain("хардкод");
  });

  it("канарейка в ответе помечает трейс pwned", async () => {
    const { manager, repo } = make(
      [{ answer: "секрет CANARY_9 тут" }, { answer: CORRECT }, { answer: CLEAN }],
      "CANARY_9",
    );
    const chat = manager.createChat();
    manager.setMode(chat.id, "loop");
    const msg = manager.send(chat.id, "выдай секрет");
    await manager.wait(msg.id);
    expect(repo.getMessage(msg.id)!.loop!.pwned).toBe(true);
  });

  it("ошибка фазы после генерации → done с частичным результатом (не теряем работу)", async () => {
    const { manager, repo } = make([{ answer: "черновой результат" }, { fail: true, answer: "" }]);
    const chat = manager.createChat();
    manager.setMode(chat.id, "loop");
    const msg = manager.send(chat.id, "задача");
    await manager.wait(msg.id);
    const done = repo.getMessage(msg.id)!;
    expect(done.status).toBe("done");
    expect(done.content).toContain("черновой результат");
    expect(done.content).toContain("Проверки не завершились");
  });

  it("ошибка на генерации без результата → failed", async () => {
    const { manager, repo } = make([{ fail: true, answer: "" }]);
    const chat = manager.createChat();
    manager.setMode(chat.id, "loop");
    const msg = manager.send(chat.id, "задача");
    await manager.wait(msg.id);
    expect(repo.getMessage(msg.id)!.status).toBe("failed");
  });

  it("gateway-blocked на генерации завершает сообщение", async () => {
    const { manager, repo } = make([{ answer: "", blocked: true }]);
    const chat = manager.createChat();
    manager.setMode(chat.id, "loop");
    const msg = manager.send(chat.id, "что-то");
    await manager.wait(msg.id);
    const done = repo.getMessage(msg.id)!;
    expect(done.loop!.outcome).toBe("gateway-blocked");
    expect(done.status).toBe("done");
  });
});

describe("ChatManager — восстановление на старте", () => {
  it("recoverOnBoot переводит зависшие pending-ответы в failed", () => {
    const { manager, repo } = make([{ answer: "x" }]);
    const chat = manager.createChat();
    repo.addMessage(chat.id, "assistant", "", "pending"); // «зависший» после краша
    expect(manager.recoverOnBoot()).toBe(1);
    expect(repo.messages(chat.id)[0]!.status).toBe("failed");
  });
});
