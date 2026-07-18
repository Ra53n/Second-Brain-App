// Тесты CRM-хранилища, контекста клиента и хендлеров MCP-инструментов.

import { beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CrmStore } from "../src/crm/crmStore.js";
import { buildCustomerContext } from "../src/crm/context.js";
import { crmToolHandlers } from "../src/mcp/crm-server.js";
import { ValidationError } from "../src/domain/errors.js";

const USERS = [
  {
    id: "u-001",
    name: "Мария",
    email: "maria@example.com",
    app_version: "1.2",
    macos_version: "14.5",
    registered_at: "2026-05-02",
    notes: "vault в Obsidian",
  },
];

const TICKETS = [
  {
    id: "t-101",
    user_id: "u-001",
    subject: "Не работает авторизация при git push",
    status: "open",
    tags: ["git-sync", "auth"],
    created_at: "2026-07-10T09:12:00Z",
    updated_at: "2026-07-10T09:12:00Z",
    messages: [{ author: "user", text: "authentication failed при push", at: "2026-07-10T09:12:00Z" }],
  },
  {
    id: "t-102",
    user_id: "u-001",
    subject: "Старый закрытый вопрос",
    status: "closed",
    tags: [],
    created_at: "2026-06-01T09:00:00Z",
    updated_at: "2026-06-02T09:00:00Z",
    messages: [],
  },
];

let dir: string;
let store: CrmStore;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "crm-"));
  writeFileSync(join(dir, "users.json"), JSON.stringify(USERS), "utf8");
  writeFileSync(join(dir, "tickets.json"), JSON.stringify(TICKETS), "utf8");
  store = new CrmStore(dir);
});

describe("CrmStore", () => {
  it("поиск по email — case-insensitive", () => {
    expect(store.findUserByEmail("MARIA@example.com")?.id).toBe("u-001");
    expect(store.findUserByEmail("ghost@example.com")).toBeNull();
    expect(store.findUserByEmail("")).toBeNull();
  });

  it("searchUsers ищет по подстроке имени/email/id", () => {
    expect(store.searchUsers("мари")).toHaveLength(1);
    expect(store.searchUsers("u-001")).toHaveLength(1);
    expect(store.searchUsers("нет такого")).toHaveLength(0);
  });

  it("фильтры тикетов по user_id и status", () => {
    expect(store.listTickets({ userId: "u-001" })).toHaveLength(2);
    expect(store.listTickets({ userId: "u-001", status: "open" })).toHaveLength(1);
    expect(store.listTickets({ status: "pending" })).toHaveLength(0);
  });

  it("addTicketComment дописывает и двигает updated_at (атомарная запись)", () => {
    const updated = store.addTicketComment("t-101", "support", "проверьте токен", "2026-07-18T12:00:00Z");
    expect(updated?.messages).toHaveLength(2);
    expect(updated?.updated_at).toBe("2026-07-18T12:00:00Z");
    // Файл на диске обновился и остался валидным JSON.
    const onDisk = JSON.parse(readFileSync(join(dir, "tickets.json"), "utf8"));
    expect(onDisk[0].messages).toHaveLength(2);
    expect(store.addTicketComment("нет", "support", "x", "2026-07-18T12:00:00Z")).toBeNull();
  });

  it("битый JSON → пустой список, не исключение", () => {
    writeFileSync(join(dir, "tickets.json"), "{мусор", "utf8");
    expect(store.listTickets()).toEqual([]);
  });

  it("валидация при замене: битые записи отклоняются", () => {
    expect(() => store.replaceUsers([{ name: "без id" }])).toThrow(ValidationError);
    expect(() => store.replaceTickets([{ id: "t", user_id: "u", status: "неизвестный" }])).toThrow(
      ValidationError,
    );
    expect(() => store.replaceUsers("не массив")).toThrow(ValidationError);
  });
});

describe("buildCustomerContext", () => {
  it("включает профиль и ТОЛЬКО открытые/pending тикеты", () => {
    const block = buildCustomerContext(store, "maria@example.com");
    expect(block).toContain("Мария");
    expect(block).toContain("t-101");
    expect(block).toContain("авторизация");
    expect(block).not.toContain("t-102"); // closed не включается
    expect(block).toContain("СПРАВОЧНЫЕ ДАННЫЕ");
  });

  it("нет записи в CRM → null", () => {
    expect(buildCustomerContext(store, "ghost@example.com")).toBeNull();
  });

  it("без открытых тикетов — явная пометка", () => {
    store.replaceTickets([]);
    const block = buildCustomerContext(store, "maria@example.com");
    expect(block).toContain("Открытых тикетов у клиента нет");
  });
});

describe("crmToolHandlers", () => {
  const now = () => new Date("2026-07-18T12:00:00Z");

  it("find_user / get_user / get_ticket", () => {
    expect(crmToolHandlers.find_user!(store, { query: "мария" }, now)).toContain("u-001");
    expect(crmToolHandlers.get_user!(store, { id: "u-001" }, now)).toContain("maria@example.com");
    expect(crmToolHandlers.get_user!(store, { id: "нет" }, now)).toContain("не найден");
    expect(crmToolHandlers.get_ticket!(store, { id: "t-101" }, now)).toContain("git push");
  });

  it("list_tickets отдаёт messageCount вместо переписки", () => {
    const out = crmToolHandlers.list_tickets!(store, { user_id: "u-001", status: "open" }, now);
    const parsed = JSON.parse(out);
    expect(parsed).toHaveLength(1);
    expect(parsed[0].messageCount).toBe(1);
    expect(parsed[0].messages).toBeUndefined();
  });

  it("add_ticket_comment пишет комментарий поддержки", () => {
    const out = crmToolHandlers.add_ticket_comment!(store, { id: "t-101", text: "обновите PAT" }, now);
    expect(out).toContain("добавлен");
    expect(store.getTicket("t-101")!.messages.at(-1)!.text).toBe("обновите PAT");
    expect(crmToolHandlers.add_ticket_comment!(store, { id: "t-101", text: "  " }, now)).toContain(
      "Пустой",
    );
  });
});
