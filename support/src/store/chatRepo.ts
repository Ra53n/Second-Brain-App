// chatRepo.ts — персистентные чат-сессии и сообщения (порт из manager-agent,
// упрощён: модель/промпт задаются глобально в настройках сервиса, не per-чат).
//
// Скоуп по владельцу: user_id = id пользователя (веб) ИЛИ NULL (admin-bearer).
// Порядок сообщений — по явной колонке seq. Каскад удаления — через FK.

import type { DB } from "./db.js";
import type {
  ChatSession,
  ChatSessionSummary,
  ChatUsage,
  StoredChatMessage,
} from "../domain/chat.js";

interface SessionRow {
  id: string;
  user_id: string | null;
  title: string;
  ticket_id: string;
  created_at: string;
  updated_at: string;
}

interface MessageRow {
  id: string;
  session_id: string;
  seq: number;
  role: string;
  content: string;
  usage_json: string | null;
  tool_calls_json: string;
  created_at: string;
}

function rowToSession(row: SessionRow): ChatSession {
  return {
    id: row.id,
    userId: row.user_id,
    title: row.title,
    ticketId: row.ticket_id ?? "",
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function rowToMessage(row: MessageRow): StoredChatMessage {
  const msg: StoredChatMessage = {
    id: row.id,
    sessionId: row.session_id,
    seq: row.seq,
    role: row.role as StoredChatMessage["role"],
    content: row.content,
    createdAt: row.created_at,
  };
  if (row.usage_json) {
    try {
      msg.usage = JSON.parse(row.usage_json) as ChatUsage;
    } catch {
      /* пропускаем */
    }
  }
  try {
    const calls = JSON.parse(row.tool_calls_json);
    if (Array.isArray(calls) && calls.length > 0) msg.toolCalls = calls;
  } catch {
    /* пропускаем */
  }
  return msg;
}

// Условие владельца: NULL требует IS NULL (в SQL '=' с NULL не совпадает).
function ownerClause(owner: string | null): { sql: string; param: Record<string, unknown> } {
  return owner === null
    ? { sql: "user_id IS NULL", param: {} }
    : { sql: "user_id = @owner", param: { owner } };
}

export class ChatRepo {
  constructor(private readonly db: DB) {}

  createSession(s: ChatSession): ChatSession {
    this.db
      .prepare(
        `INSERT INTO chat_sessions (id, user_id, title, ticket_id, created_at, updated_at)
         VALUES (@id, @user_id, @title, @ticket_id, @created_at, @updated_at)`,
      )
      .run({
        id: s.id,
        user_id: s.userId,
        title: s.title,
        ticket_id: s.ticketId,
        created_at: s.createdAt,
        updated_at: s.updatedAt,
      });
    return s;
  }

  /** Привязывает чат к созданному CRM-обращению. */
  setTicketId(sessionId: string, ticketId: string): void {
    this.db.prepare(`UPDATE chat_sessions SET ticket_id = ? WHERE id = ?`).run(ticketId, sessionId);
  }

  /** Сессия по id в пределах владельца (чужая → null). */
  getSession(id: string, owner: string | null): ChatSession | null {
    const oc = ownerClause(owner);
    const row = this.db
      .prepare(`SELECT * FROM chat_sessions WHERE id = @id AND ${oc.sql}`)
      .get({ id, ...oc.param }) as SessionRow | undefined;
    return row ? rowToSession(row) : null;
  }

  deleteSession(id: string, owner: string | null): boolean {
    const oc = ownerClause(owner);
    return (
      (this.db
        .prepare(`DELETE FROM chat_sessions WHERE id = @id AND ${oc.sql}`)
        .run({ id, ...oc.param }).changes as number) > 0
    );
  }

  listSessions(owner: string | null, limit: number): ChatSessionSummary[] {
    const lim = Math.max(1, Math.min(limit || 50, 200));
    const oc = ownerClause(owner);
    const rows = this.db
      .prepare(
        `SELECT s.*, (SELECT COUNT(*) FROM chat_messages m WHERE m.session_id = s.id) AS message_count
         FROM chat_sessions s
         WHERE ${oc.sql.replace(/user_id/g, "s.user_id")}
         ORDER BY s.updated_at DESC, s.id DESC LIMIT @lim`,
      )
      .all({ ...oc.param, lim }) as Array<SessionRow & { message_count: number }>;
    return rows.map((r) => ({
      id: r.id,
      title: r.title,
      messageCount: r.message_count,
      createdAt: r.created_at,
      updatedAt: r.updated_at,
    }));
  }

  listMessages(sessionId: string): StoredChatMessage[] {
    const rows = this.db
      .prepare(`SELECT * FROM chat_messages WHERE session_id = ? ORDER BY seq ASC`)
      .all(sessionId) as MessageRow[];
    return rows.map(rowToMessage);
  }

  /** Добавляет сообщение (seq = MAX+1) и двигает updated_at сессии — атомарно. */
  appendMessage(
    sessionId: string,
    msg: {
      id: string;
      role: string;
      content: string;
      usage?: ChatUsage;
      toolCalls?: Array<{ name: string; ok: boolean }>;
      createdAt: string;
    },
  ): StoredChatMessage {
    const tx = this.db.transaction(() => {
      const maxSeq = this.db
        .prepare(`SELECT COALESCE(MAX(seq), 0) AS m FROM chat_messages WHERE session_id = ?`)
        .get(sessionId) as { m: number };
      const seq = maxSeq.m + 1;
      this.db
        .prepare(
          `INSERT INTO chat_messages (id, session_id, seq, role, content, usage_json, tool_calls_json, created_at)
           VALUES (@id, @session_id, @seq, @role, @content, @usage_json, @tool_calls_json, @created_at)`,
        )
        .run({
          id: msg.id,
          session_id: sessionId,
          seq,
          role: msg.role,
          content: msg.content,
          usage_json: msg.usage ? JSON.stringify(msg.usage) : null,
          tool_calls_json: JSON.stringify(msg.toolCalls ?? []),
          created_at: msg.createdAt,
        });
      this.db
        .prepare(`UPDATE chat_sessions SET updated_at = ? WHERE id = ?`)
        .run(msg.createdAt, sessionId);
      return seq;
    });
    const seq = tx();
    return {
      id: msg.id,
      sessionId,
      seq,
      role: msg.role as StoredChatMessage["role"],
      content: msg.content,
      usage: msg.usage,
      toolCalls: msg.toolCalls,
      createdAt: msg.createdAt,
    };
  }

  setTitle(sessionId: string, title: string): void {
    this.db.prepare(`UPDATE chat_sessions SET title = ? WHERE id = ?`).run(title, sessionId);
  }
}
