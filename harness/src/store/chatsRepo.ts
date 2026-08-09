// chatsRepo.ts — персистентность чатов и сообщений (SQLite). Порт роли
// ChatPersistence + CRUD из ChatViewModel. Снисходительный декод loop_json:
// битый JSON → null/дефолты, приложение не падает.

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
      phases: Array.isArray(t.phases) ? t.phases : [],
    };
  } catch {
    return null; // битый трейс — просто без него, ответ остаётся
  }
}

function rowToChat(r: Record<string, unknown>): Chat {
  return {
    id: String(r.id),
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
    createdAt: String(r.created_at ?? ""),
  };
}

export class ChatsRepo {
  constructor(
    private readonly db: DB,
    private readonly now: () => Date = () => new Date(),
  ) {}

  // ── Чаты ────────────────────────────────────────────────────────────────────
  createChat(): Chat {
    const ts = this.now().toISOString();
    const chat: Chat = { id: randomUUID(), title: "Новый чат", mode: "normal", createdAt: ts, updatedAt: ts };
    this.db
      .prepare("INSERT INTO chats (id, title, mode, created_at, updated_at) VALUES (?,?,?,?,?)")
      .run(chat.id, chat.title, chat.mode, ts, ts);
    return chat;
  }

  listChats(limit = 200): Chat[] {
    return (this.db.prepare("SELECT * FROM chats ORDER BY updated_at DESC LIMIT ?").all(limit) as Array<
      Record<string, unknown>
    >).map(rowToChat);
  }

  getChat(id: string): Chat | null {
    const row = this.db.prepare("SELECT * FROM chats WHERE id=?").get(id) as Record<string, unknown> | undefined;
    return row ? rowToChat(row) : null;
  }

  rename(id: string, title: string): void {
    const t = title.trim();
    if (!t) return; // пустой заголовок игнорируем (как в приложении)
    this.db.prepare("UPDATE chats SET title=?, updated_at=? WHERE id=?").run(t.slice(0, 80), this.now().toISOString(), id);
  }

  setMode(id: string, mode: ChatMode): void {
    this.db.prepare("UPDATE chats SET mode=?, updated_at=? WHERE id=?").run(coerceMode(mode), this.now().toISOString(), id);
  }

  touch(id: string): void {
    this.db.prepare("UPDATE chats SET updated_at=? WHERE id=?").run(this.now().toISOString(), id);
  }

  deleteChat(id: string): void {
    const tx = this.db.transaction(() => {
      this.db.prepare("DELETE FROM messages WHERE chat_id=?").run(id);
      this.db.prepare("DELETE FROM chats WHERE id=?").run(id);
    });
    tx();
  }

  // ── Сообщения ─────────────────────────────────────────────────────────────────
  messages(chatId: string): Message[] {
    return (this.db.prepare("SELECT * FROM messages WHERE chat_id=? ORDER BY seq ASC").all(chatId) as Array<
      Record<string, unknown>
    >).map(rowToMessage);
  }

  getMessage(id: string): Message | null {
    const row = this.db.prepare("SELECT * FROM messages WHERE id=?").get(id) as Record<string, unknown> | undefined;
    return row ? rowToMessage(row) : null;
  }

  private nextSeq(chatId: string): number {
    const row = this.db.prepare("SELECT COALESCE(MAX(seq), -1) AS m FROM messages WHERE chat_id=?").get(chatId) as {
      m: number;
    };
    return row.m + 1;
  }

  /** Добавляет сообщение, возвращает его. seq назначается атомарно. */
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
      createdAt: this.now().toISOString(),
    };
    this.db
      .prepare(
        "INSERT INTO messages (id, chat_id, seq, role, content, status, generation, error_text, loop_json, created_at) VALUES (@id,@chatId,@seq,@role,@content,@status,0,NULL,NULL,@createdAt)",
      )
      .run({ id: msg.id, chatId, seq: msg.seq, role, content, status, createdAt: msg.createdAt });
    this.touch(chatId);
    return msg;
  }

  /** Инкремент поколения сообщения (фоновый прогон против гонок). */
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
    patch: { content?: string; status?: MsgStatus; errorText?: string | null; loop?: LoopTrace | null },
  ): boolean {
    const cur = this.getMessage(id);
    if (!cur) return false;
    const next = {
      content: patch.content ?? cur.content,
      status: patch.status ?? cur.status,
      errorText: patch.errorText === undefined ? cur.errorText : patch.errorText,
      loop: patch.loop === undefined ? cur.loop : patch.loop,
    };
    const res = this.db
      .prepare(
        "UPDATE messages SET content=@content, status=@status, error_text=@errorText, loop_json=@loop WHERE id=@id AND generation=@generation",
      )
      .run({
        id,
        generation,
        content: next.content,
        status: next.status,
        errorText: next.errorText,
        loop: next.loop ? JSON.stringify(next.loop) : null,
      });
    if (res.changes > 0) this.touch(cur.chatId);
    return res.changes > 0;
  }

  /** На старте сервиса: зависшие pending-ответы → failed (чат: проще resend, чем resume). */
  failPendingOnBoot(): number {
    const res = this.db
      .prepare("UPDATE messages SET status='failed', error_text='Прервано рестартом сервиса — отправьте сообщение ещё раз' WHERE status='pending'")
      .run();
    return res.changes;
  }
}
