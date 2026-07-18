// usersRepo.ts — хранение пользователей веб-интерфейса и серверных сессий
// (порт из manager-agent + колонка email: связь логин-аккаунта с CRM-записью).
//
// Секреты наружу НЕ отдаём: password_hash и token_hash остаются в БД.

import type { DB } from "./db.js";

export interface UserRow {
  id: string;
  username: string;
  email: string;
  password_hash: string;
  is_admin: number;
  settings_json: string;
  created_at: string;
}

/** Публичное представление пользователя (без хеша пароля). */
export interface PublicUser {
  id: string;
  username: string;
  email: string;
  isAdmin: boolean;
  createdAt: string;
}

export function toPublicUser(row: UserRow): PublicUser {
  return {
    id: row.id,
    username: row.username,
    email: row.email,
    isAdmin: row.is_admin === 1,
    createdAt: row.created_at,
  };
}

export interface SessionRow {
  id: string;
  user_id: string;
  token_hash: string;
  created_at: string;
  expires_at: string;
  last_seen: string;
}

export class UsersRepo {
  constructor(private readonly db: DB) {}

  insertUser(row: UserRow): void {
    this.db
      .prepare(
        `INSERT INTO users (id, username, email, password_hash, is_admin, settings_json, created_at)
         VALUES (@id, @username, @email, @password_hash, @is_admin, @settings_json, @created_at)`,
      )
      .run(row);
  }

  findByUsername(username: string): UserRow | null {
    return (
      (this.db.prepare(`SELECT * FROM users WHERE username = ?`).get(username) as UserRow | undefined) ??
      null
    );
  }

  findById(id: string): UserRow | null {
    return (
      (this.db.prepare(`SELECT * FROM users WHERE id = ?`).get(id) as UserRow | undefined) ?? null
    );
  }

  listUsers(): UserRow[] {
    return this.db.prepare(`SELECT * FROM users ORDER BY created_at ASC`).all() as UserRow[];
  }

  deleteUser(id: string): number {
    return this.db.prepare(`DELETE FROM users WHERE id = ?`).run(id).changes as number;
  }

  // ── Сессии ─────────────────────────────────────────────────────────────────

  insertSession(row: SessionRow): void {
    this.db
      .prepare(
        `INSERT INTO user_sessions (id, user_id, token_hash, created_at, expires_at, last_seen)
         VALUES (@id, @user_id, @token_hash, @created_at, @expires_at, @last_seen)`,
      )
      .run(row);
  }

  findSessionByTokenHash(tokenHash: string): SessionRow | null {
    return (
      (this.db.prepare(`SELECT * FROM user_sessions WHERE token_hash = ?`).get(tokenHash) as
        | SessionRow
        | undefined) ?? null
    );
  }

  touchSession(id: string, lastSeen: string): void {
    this.db.prepare(`UPDATE user_sessions SET last_seen = ? WHERE id = ?`).run(lastSeen, id);
  }

  deleteSessionByTokenHash(tokenHash: string): number {
    return this.db.prepare(`DELETE FROM user_sessions WHERE token_hash = ?`).run(tokenHash)
      .changes as number;
  }

  deleteExpiredSessions(nowIso: string): number {
    return this.db.prepare(`DELETE FROM user_sessions WHERE expires_at <= ?`).run(nowIso)
      .changes as number;
  }
}
