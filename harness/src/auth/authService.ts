// authService.ts — регистрация, логин, серверные сессии (порт support, без email).
//
// Сессия = случайный opaque-токен в httpOnly-cookie; в БД лежит только его
// sha256-хеш + срок. Мгновенный отзыв (logout/удаление пользователя каскадом).

import { randomBytes, createHash, randomUUID } from "node:crypto";
import { ConflictError, ValidationError } from "../domain/errors.js";
import { hashPassword, verifyPassword } from "./passwords.js";
import { toPublicUser, type PublicUser, type UsersRepo, type UserRow } from "../store/usersRepo.js";

const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 дней
const MIN_USERNAME = 2;
const MIN_PASSWORD = 6;

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export class AuthService {
  constructor(
    private readonly repo: UsersRepo,
    private readonly adminUser: string = "",
    private readonly now: () => Date = () => new Date(),
  ) {}

  /** Регистрирует пользователя. Первый в системе (или совпавший с HARNESS_ADMIN_USER)
   *  получает роль администратора. */
  async createUser(username: string, password: string): Promise<PublicUser> {
    const uname = username.trim();
    if (uname.length < MIN_USERNAME) {
      throw new ValidationError(`Логин слишком короткий (мин. ${MIN_USERNAME} символа).`);
    }
    if (password.length < MIN_PASSWORD) {
      throw new ValidationError(`Пароль слишком короткий (мин. ${MIN_PASSWORD} символов).`);
    }
    if (this.repo.findByUsername(uname)) {
      throw new ConflictError(`Пользователь «${uname}» уже существует.`);
    }
    const base = {
      id: randomUUID(),
      username: uname,
      password_hash: await hashPassword(password),
      created_at: this.now().toISOString(),
    };
    // Роль админа решается атомарно с insert (транзакция) — без гонки «первый = админ».
    let isAdmin: boolean;
    try {
      isAdmin = this.repo.insertDecidingAdmin(base, this.adminUser);
    } catch {
      // UNIQUE(username) — гонка одинакового логина между pre-check и insert.
      throw new ConflictError(`Пользователь «${uname}» уже существует.`);
    }
    return toPublicUser({ ...base, is_admin: isAdmin ? 1 : 0 });
  }

  listUsers(): PublicUser[] {
    return this.repo.listUsers().map(toPublicUser);
  }

  deleteUser(id: string): boolean {
    return this.repo.deleteUser(id) > 0;
  }

  /** Проверяет логин/пароль; null — неверные данные (не раскрываем, что именно). */
  async verifyLogin(username: string, password: string): Promise<UserRow | null> {
    const row = this.repo.findByUsername(username.trim());
    if (!row) {
      // Всё равно считаем хеш, чтобы время ответа не выдавало наличие юзера.
      await verifyPassword(password, "scrypt$16384$00$00");
      return null;
    }
    const ok = await verifyPassword(password, row.password_hash);
    return ok ? row : null;
  }

  /** Создаёт серверную сессию; возвращает opaque-токен для cookie. */
  createSession(userId: string): { token: string; expiresAt: string } {
    const token = randomBytes(32).toString("base64url");
    const now = this.now();
    const expiresAt = new Date(now.getTime() + SESSION_TTL_MS).toISOString();
    this.repo.insertSession({
      id: randomUUID(),
      user_id: userId,
      token_hash: hashToken(token),
      created_at: now.toISOString(),
      expires_at: expiresAt,
      last_seen: now.toISOString(),
    });
    return { token, expiresAt };
  }

  /** По токену из cookie возвращает пользователя (null — нет/истёк). */
  resolveSession(token: string): PublicUser | null {
    if (!token) return null;
    const session = this.repo.findSessionByTokenHash(hashToken(token));
    if (!session) return null;
    const now = this.now();
    if (new Date(session.expires_at).getTime() <= now.getTime()) {
      this.repo.deleteSessionByTokenHash(session.token_hash);
      return null;
    }
    this.repo.touchSession(session.id, now.toISOString());
    const user = this.repo.findById(session.user_id);
    return user ? toPublicUser(user) : null;
  }

  revokeSession(token: string): void {
    if (token) this.repo.deleteSessionByTokenHash(hashToken(token));
  }
}
