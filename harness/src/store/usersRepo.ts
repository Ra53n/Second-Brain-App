// usersRepo.ts — хранение пользователей чата и серверных сессий (порт support,
// без колонки email/settings). Секреты наружу НЕ отдаём: password_hash и
// token_hash остаются в БД.

import type { DB } from "./db.js";

export interface UserRow {
  id: string;
  username: string;
  password_hash: string;
  is_admin: number;
  created_at: string;
}

/** Публичное представление пользователя (без хеша пароля). */
export interface PublicUser {
  id: string;
  username: string;
  isAdmin: boolean;
  createdAt: string;
}

export function toPublicUser(row: UserRow): PublicUser {
  return { id: row.id, username: row.username, isAdmin: row.is_admin === 1, createdAt: row.created_at };
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

  countUsers(): number {
    return (this.db.prepare("SELECT COUNT(*) AS n FROM users").get() as { n: number }).n;
  }

  insertUser(row: UserRow): void {
    this.db
      .prepare(
        `INSERT INTO users (id, username, password_hash, is_admin, created_at)
         VALUES (@id, @username, @password_hash, @is_admin, @created_at)`,
      )
      .run(row);
  }

  /** Вставляет пользователя, решая роль админа АТОМАРНО (count+insert в одной
   *  транзакции) — иначе два одновременных первых запроса оба стали бы админами.
   *  Возвращает итоговое is_admin. */
  insertDecidingAdmin(
    base: { id: string; username: string; password_hash: string; created_at: string },
    adminUser: string,
  ): boolean {
    const tx = this.db.transaction(() => {
      const first = (this.db.prepare("SELECT COUNT(*) AS n FROM users").get() as { n: number }).n === 0;
      const isAdmin = first || (adminUser !== "" && base.username === adminUser);
      this.db
        .prepare(
          `INSERT INTO users (id, username, password_hash, is_admin, created_at)
           VALUES (@id, @username, @password_hash, @is_admin, @created_at)`,
        )
        .run({ ...base, is_admin: isAdmin ? 1 : 0 });
      return isAdmin;
    });
    return tx();
  }

  findByUsername(username: string): UserRow | null {
    return (this.db.prepare("SELECT * FROM users WHERE username = ?").get(username) as UserRow | undefined) ?? null;
  }

  findById(id: string): UserRow | null {
    return (this.db.prepare("SELECT * FROM users WHERE id = ?").get(id) as UserRow | undefined) ?? null;
  }

  listUsers(): UserRow[] {
    return this.db.prepare("SELECT * FROM users ORDER BY created_at ASC").all() as UserRow[];
  }

  deleteUser(id: string): number {
    return this.db.prepare("DELETE FROM users WHERE id = ?").run(id).changes as number;
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
      (this.db.prepare("SELECT * FROM user_sessions WHERE token_hash = ?").get(tokenHash) as SessionRow | undefined) ??
      null
    );
  }

  touchSession(id: string, lastSeen: string): void {
    this.db.prepare("UPDATE user_sessions SET last_seen = ? WHERE id = ?").run(lastSeen, id);
  }

  deleteSessionByTokenHash(tokenHash: string): number {
    return this.db.prepare("DELETE FROM user_sessions WHERE token_hash = ?").run(tokenHash).changes as number;
  }

  deleteExpiredSessions(nowIso: string): number {
    return this.db.prepare("DELETE FROM user_sessions WHERE expires_at <= ?").run(nowIso).changes as number;
  }
}
