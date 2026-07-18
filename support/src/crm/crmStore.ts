// crmStore.ts — CRM-хранилище на JSON-файлах (референс вместо реальной CRM).
//
// users.json / tickets.json лежат в CRM_DIR на VPS. Чтение — снисходительное
// (битый JSON → пустой список, сервис не падает); запись — атомарная
// (tmp + rename), чтобы конкурентный читатель не увидел полфайла. Известное
// ограничение (задокументировано): читатель-модификатор из MCP-процесса и
// админ-редактор могут потерять чужой апдейт (last-write-wins) — приемлемо для
// референса с низким трафиком.

import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { CrmTicket, CrmUser, TicketStatus } from "../domain/types.js";
import { TICKET_STATUSES } from "../domain/types.js";
import { ValidationError } from "../domain/errors.js";

export class CrmStore {
  constructor(private readonly dir: string) {}

  private usersPath(): string {
    return join(this.dir, "users.json");
  }

  private ticketsPath(): string {
    return join(this.dir, "tickets.json");
  }

  private readArray<T>(path: string): T[] {
    try {
      const parsed = JSON.parse(readFileSync(path, "utf8"));
      return Array.isArray(parsed) ? (parsed as T[]) : [];
    } catch {
      return [];
    }
  }

  private writeAtomic(path: string, value: unknown): void {
    const tmp = `${path}.tmp`;
    writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n", "utf8");
    renameSync(tmp, path);
  }

  // ── Пользователи ───────────────────────────────────────────────────────────

  listUsers(): CrmUser[] {
    return this.readArray<CrmUser>(this.usersPath());
  }

  getUser(id: string): CrmUser | null {
    return this.listUsers().find((u) => u.id === id) ?? null;
  }

  findUserByEmail(email: string): CrmUser | null {
    const needle = email.trim().toLowerCase();
    if (!needle) return null;
    return this.listUsers().find((u) => (u.email ?? "").toLowerCase() === needle) ?? null;
  }

  /** Поиск по имени/email/id (подстрока, регистронезависимо). */
  searchUsers(query: string): CrmUser[] {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    return this.listUsers().filter(
      (u) =>
        u.id.toLowerCase().includes(q) ||
        (u.name ?? "").toLowerCase().includes(q) ||
        (u.email ?? "").toLowerCase().includes(q),
    );
  }

  /** Полная замена users.json (админ-редактор) с валидацией схемы. */
  replaceUsers(users: unknown): CrmUser[] {
    if (!Array.isArray(users)) throw new ValidationError("users.json: ожидается массив.");
    for (const u of users as Array<Record<string, unknown>>) {
      if (!u || typeof u.id !== "string" || !u.id) {
        throw new ValidationError("users.json: у каждого пользователя обязателен строковый id.");
      }
      if (typeof u.email !== "string") {
        throw new ValidationError(`users.json: у «${u.id}» отсутствует email (строка).`);
      }
    }
    this.writeAtomic(this.usersPath(), users);
    return users as CrmUser[];
  }

  // ── Тикеты ─────────────────────────────────────────────────────────────────

  listTickets(filter: { userId?: string; status?: TicketStatus } = {}): CrmTicket[] {
    let tickets = this.readArray<CrmTicket>(this.ticketsPath());
    if (filter.userId) tickets = tickets.filter((t) => t.user_id === filter.userId);
    if (filter.status) tickets = tickets.filter((t) => t.status === filter.status);
    return tickets;
  }

  getTicket(id: string): CrmTicket | null {
    return this.listTickets().find((t) => t.id === id) ?? null;
  }

  /** Добавляет комментарий в тикет (read-modify-write + атомарная запись). */
  addTicketComment(
    ticketId: string,
    author: "user" | "support",
    text: string,
    at: string,
  ): CrmTicket | null {
    const tickets = this.readArray<CrmTicket>(this.ticketsPath());
    const ticket = tickets.find((t) => t.id === ticketId);
    if (!ticket) return null;
    ticket.messages = [...(ticket.messages ?? []), { author, text, at }];
    ticket.updated_at = at;
    this.writeAtomic(this.ticketsPath(), tickets);
    return ticket;
  }

  /** Полная замена tickets.json (админ-редактор) с валидацией схемы. */
  replaceTickets(tickets: unknown): CrmTicket[] {
    if (!Array.isArray(tickets)) throw new ValidationError("tickets.json: ожидается массив.");
    for (const t of tickets as Array<Record<string, unknown>>) {
      if (!t || typeof t.id !== "string" || !t.id) {
        throw new ValidationError("tickets.json: у каждого тикета обязателен строковый id.");
      }
      if (typeof t.user_id !== "string" || !t.user_id) {
        throw new ValidationError(`tickets.json: у «${t.id}» отсутствует user_id.`);
      }
      if (!TICKET_STATUSES.includes(t.status as TicketStatus)) {
        throw new ValidationError(
          `tickets.json: у «${t.id}» некорректный status (open|pending|closed).`,
        );
      }
    }
    this.writeAtomic(this.ticketsPath(), tickets);
    return tickets as CrmTicket[];
  }
}
