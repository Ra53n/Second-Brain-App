// chatsRepo.ts — персистентность чатов и сообщений (SQLite), с изоляцией по
// владельцу (owner = user.id). Порт паттерна ownerClause из support/chatRepo.
// Снисходительный декод loop_json: битый JSON → null, приложение не падает.

import { randomUUID } from "node:crypto";
import type { DB } from "./db.js";
import type { Chat, ChatMode, LoopTrace, Message, MsgRole, MsgStatus } from "../domain/chat.js";

const MODES = new Set<ChatMode>(["normal", "loop"]);
const ROLES = new Set<MsgRole>(["user", "assistant"]);
const STATUSES = new Set<MsgStatus>(["done", "pending", "failed"]);

function coerceMode(v: unknown): ChatMode {
  return MODES.has(v as ChatMode) ? (v as ChatMode) : "normal";
}

function decodeLoop(raw: unknown): LoopTrace | null {
  if (typeof raw !== "string" || !raw) return null;
  try {
    const t = JSON.parse(raw) as Partial<LoopTrace>;
    if (!t || typeof t !== "object") return null;
    return {
      rounds: typeof t.rounds === "number" ? t.rounds : 0,
      outcome: typeof t.outcome === "string" ? t.outcome : null,
      pwned: t.pwned === true,
      costUsd: typeof t.costUsd === "number" ? t.costUsd : 0,
      totalTokens: typeof t.totalTokens === "number" ? t.totalTokens : 0,
      durationMs: typeof t.durationMs === "number" ? t.durationMs : 0,
      sources: Array.isArray(t.sources)
        ? (t.sources as unknown[])
            .filter((s) => !!s && typeof s === "object")
            .map((s) => {
              const o = s as Record<string, unknown>;
              return {
                type: o.type === "search" ? ("search" as const) : ("link" as const),
                title: String(o.title ?? ""),
                url: String(o.url ?? ""),
              };
            })
        : [],
      phases: Array.isArray(t.phases) ? t.phases : [],
    };
  } catch {
    return null;
  }
}

function decodeKinds(raw: unknown): string[] {
  if (typeof raw !== "string" || !raw) return [];
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v) ? v.map(String) : [];
  } catch {
    return [];
  }
}

function rowToChat(r: Record<string, unknown>): Chat {
  return {
    id: String(r.id),
    userId: String(r.user_id ?? ""),
    title: String(r.title ?? "Новый чат"),
    mode: coerceMode(r.mode),
    createdAt: String(r.created_at ?? ""),
    updatedAt: String(r.updated_at ?? ""),
  };
}

function rowToMessage(r: Record<string, unknown>): Message {
  const role = ROLES.has(r.role as MsgRole) ? (r.role as MsgRole) : "assistant";
  const status = STATUSES.has(r.status as MsgStatus) ? (r.status as MsgStatus) : "done";
  return {
    id: String(r.id),
    chatId: String(r.chat_id),
    seq: typeof r.seq === "number" ? r.seq : 0,
    role,
    content: String(r.content ?? ""),
    status,
    generation: typeof r.generation === "number" ? r.generation : 0,
    errorText: typeof r.error_text === "string" ? r.error_text : null,
    loop: decodeLoop(r.loop_json),
    alert: r.alert === 1,
    alertKinds: decodeKinds(r.alert_kinds),
    createdAt: String(r.created_at ?? ""),
  };
}

/** Строка админ-журнала: сообщение + владелец + заголовок чата. */
export interface AdminMessageRow extends Message {
  username: string;
  chatTitle: string;
}

export interface AdminChatRow extends Chat {
  username: string;
  messageCount: number;
}

export interface AdminStats {
  users: number;
  chats: number;
  messages: number;
  alerts: number;
  pwned: number;
  costUsd: number;
}

export class ChatsRepo {
  constructor(
    private readonly db: DB,
    private readonly now: () => Date = () => new Date(),
  ) {}

  // ── Чаты (скоуп по владельцу) ────────────────────────────────────────────────
  createChat(owner: string): Chat {
    const ts = this.now().toISOString();
    const chat: Chat = { id: randomUUID(), userId: owner, title: "Новый чат", mode: "normal", createdAt: ts, updatedAt: ts };
    this.db
      .prepare("INSERT INTO chats (id, user_id, title, mode, created_at, updated_at) VALUES (?,?,?,?,?,?)")
      .run(chat.id, owner, chat.title, chat.mode, ts, ts);
    return chat;
  }

  listChats(owner: string, limit = 200): Chat[] {
    return (
      this.db.prepare("SELECT * FROM chats WHERE user_id=? ORDER BY updated_at DESC LIMIT ?").all(owner, limit) as Array<
        Record<string, unknown>
      >
    ).map(rowToChat);
  }

  getChat(id: string, owner: string): Chat | null {
    const row = this.db.prepare("SELECT * FROM chats WHERE id=? AND user_id=?").get(id, owner) as
      | Record<string, unknown>
      | undefined;
    return row ? rowToChat(row) : null;
  }

  rename(id: string, owner: string, title: string): void {
    const t = title.trim();
    if (!t) return;
    this.db
      .prepare("UPDATE chats SET title=?, updated_at=? WHERE id=? AND user_id=?")
      .run(t.slice(0, 80), this.now().toISOString(), id, owner);
  }

  setMode(id: string, owner: string, mode: ChatMode): void {
    this.db
      .prepare("UPDATE chats SET mode=?, updated_at=? WHERE id=? AND user_id=?")
      .run(coerceMode(mode), this.now().toISOString(), id, owner);
  }

  private touch(id: string): void {
    this.db.prepare("UPDATE chats SET updated_at=? WHERE id=?").run(this.now().toISOString(), id);
  }

  /** Удаляет чат в пределах владельца; сообщения уходят по FK-каскаду. */
  deleteChat(id: string, owner: string): boolean {
    return (this.db.prepare("DELETE FROM chats WHERE id=? AND user_id=?").run(id, owner).changes as number) > 0;
  }

  // ── Сообщения ────────────────────────────────────────────────────────────────
  // messages()/getMessage()/addMessage() — внутренние: владелец проверен на
  // уровне маршрута через getChat(chatId, owner). Наружу (поллинг) — только
  // getMessageForOwner().
  messages(chatId: string): Message[] {
    return (
      this.db.prepare("SELECT * FROM messages WHERE chat_id=? ORDER BY seq ASC").all(chatId) as Array<
        Record<string, unknown>
      >
    ).map(rowToMessage);
  }

  getMessage(id: string): Message | null {
    const row = this.db.prepare("SELECT * FROM messages WHERE id=?").get(id) as Record<string, unknown> | undefined;
    return row ? rowToMessage(row) : null;
  }

  /** Сообщение по id ТОЛЬКО если его чат принадлежит owner (поллинг). */
  getMessageForOwner(id: string, owner: string): Message | null {
    const row = this.db
      .prepare("SELECT m.* FROM messages m JOIN chats c ON c.id = m.chat_id WHERE m.id=? AND c.user_id=?")
      .get(id, owner) as Record<string, unknown> | undefined;
    return row ? rowToMessage(row) : null;
  }

  private nextSeq(chatId: string): number {
    const row = this.db.prepare("SELECT COALESCE(MAX(seq), -1) AS m FROM messages WHERE chat_id=?").get(chatId) as {
      m: number;
    };
    return row.m + 1;
  }

  addMessage(chatId: string, role: MsgRole, content: string, status: MsgStatus): Message {
    const msg: Message = {
      id: randomUUID(),
      chatId,
      seq: this.nextSeq(chatId),
      role,
      content,
      status,
      generation: 0,
      errorText: null,
      loop: null,
      alert: false,
      alertKinds: [],
      createdAt: this.now().toISOString(),
    };
    this.db
      .prepare(
        "INSERT INTO messages (id, chat_id, seq, role, content, status, generation, error_text, loop_json, alert, alert_kinds, created_at) VALUES (@id,@chatId,@seq,@role,@content,@status,0,NULL,NULL,0,'[]',@createdAt)",
      )
      .run({ id: msg.id, chatId, seq: msg.seq, role, content, status, createdAt: msg.createdAt });
    this.touch(chatId);
    return msg;
  }

  bumpMessageGeneration(id: string): number {
    this.db.prepare("UPDATE messages SET generation = generation + 1 WHERE id=?").run(id);
    const row = this.db.prepare("SELECT generation FROM messages WHERE id=?").get(id) as { generation: number } | undefined;
    return row?.generation ?? 0;
  }

  generationOf(id: string): number {
    const row = this.db.prepare("SELECT generation FROM messages WHERE id=?").get(id) as { generation: number } | undefined;
    return row?.generation ?? -1;
  }

  /** Обновляет сообщение при совпадении поколения (устаревший воркер → 0 строк). */
  updateMessage(
    id: string,
    generation: number,
    patch: {
      content?: string;
      status?: MsgStatus;
      errorText?: string | null;
      loop?: LoopTrace | null;
      alert?: boolean;
      alertKinds?: string[];
    },
  ): boolean {
    const cur = this.getMessage(id);
    if (!cur) return false;
    const next = {
      content: patch.content ?? cur.content,
      status: patch.status ?? cur.status,
      errorText: patch.errorText === undefined ? cur.errorText : patch.errorText,
      loop: patch.loop === undefined ? cur.loop : patch.loop,
      alert: patch.alert === undefined ? cur.alert : patch.alert,
      alertKinds: patch.alertKinds === undefined ? cur.alertKinds : patch.alertKinds,
    };
    const res = this.db
      .prepare(
        "UPDATE messages SET content=@content, status=@status, error_text=@errorText, loop_json=@loop, alert=@alert, alert_kinds=@alertKinds WHERE id=@id AND generation=@generation",
      )
      .run({
        id,
        generation,
        content: next.content,
        status: next.status,
        errorText: next.errorText,
        loop: next.loop ? JSON.stringify(next.loop) : null,
        alert: next.alert ? 1 : 0,
        alertKinds: JSON.stringify(next.alertKinds),
      });
    if (res.changes > 0) this.touch(cur.chatId);
    return res.changes > 0;
  }

  failPendingOnBoot(): number {
    return this.db
      .prepare(
        "UPDATE messages SET status='failed', error_text='Прервано рестартом сервиса — отправьте сообщение ещё раз' WHERE status='pending'",
      )
      .run().changes as number;
  }

  // ── Админ-выборки (все пользователи) ─────────────────────────────────────────
  listAllChats(limit = 200): AdminChatRow[] {
    const rows = this.db
      .prepare(
        `SELECT c.*, u.username AS username,
                (SELECT COUNT(*) FROM messages m WHERE m.chat_id = c.id) AS message_count
         FROM chats c JOIN users u ON u.id = c.user_id
         ORDER BY c.updated_at DESC LIMIT ?`,
      )
      .all(limit) as Array<Record<string, unknown>>;
    return rows.map((r) => ({
      ...rowToChat(r),
      username: String(r.username ?? ""),
      messageCount: typeof r.message_count === "number" ? r.message_count : 0,
    }));
  }

  listAllMessages(alertsOnly: boolean, limit = 200): AdminMessageRow[] {
    const where = alertsOnly ? "WHERE m.alert = 1" : "";
    const rows = this.db
      .prepare(
        `SELECT m.*, u.username AS username, c.title AS chat_title
         FROM messages m JOIN chats c ON c.id = m.chat_id JOIN users u ON u.id = c.user_id
         ${where}
         ORDER BY m.created_at DESC LIMIT ?`,
      )
      .all(limit) as Array<Record<string, unknown>>;
    return rows.map((r) => ({ ...rowToMessage(r), username: String(r.username ?? ""), chatTitle: String(r.chat_title ?? "") }));
  }

  /** Чат по id без скоупа — только для админ-drill-down. */
  getChatById(id: string): Chat | null {
    const row = this.db.prepare("SELECT * FROM chats WHERE id=?").get(id) as Record<string, unknown> | undefined;
    return row ? rowToChat(row) : null;
  }

  adminStats(): AdminStats {
    const one = (sql: string): number => (this.db.prepare(sql).get() as { n: number }).n;
    return {
      users: one("SELECT COUNT(*) AS n FROM users"),
      chats: one("SELECT COUNT(*) AS n FROM chats"),
      messages: one("SELECT COUNT(*) AS n FROM messages"),
      alerts: one("SELECT COUNT(*) AS n FROM messages WHERE alert = 1"),
      pwned: one("SELECT COUNT(*) AS n FROM messages WHERE alert_kinds LIKE '%pwned%'"),
      costUsd: (this.db.prepare("SELECT COALESCE(SUM(cost),0) AS n FROM (SELECT json_extract(loop_json,'$.costUsd') AS cost FROM messages WHERE loop_json IS NOT NULL)").get() as { n: number }).n,
    };
  }
}
