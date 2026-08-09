// authService.test.ts — регистрация (первый=админ), логин, сессии, TTL.

import { describe, it, expect } from "vitest";
import { openDb } from "../src/store/db.js";
import { UsersRepo } from "../src/store/usersRepo.js";
import { AuthService } from "../src/auth/authService.js";
import { hashPassword, verifyPassword } from "../src/auth/passwords.js";

function svc(now: () => Date = () => new Date("2026-01-01T00:00:00Z"), adminUser = ""): { auth: AuthService; users: UsersRepo } {
  const users = new UsersRepo(openDb(":memory:"));
  return { auth: new AuthService(users, adminUser, now), users };
}

describe("passwords", () => {
  it("хеш проверяется, неверный пароль — нет", async () => {
    const h = await hashPassword("secret123");
    expect(h.startsWith("scrypt$")).toBe(true);
    expect(await verifyPassword("secret123", h)).toBe(true);
    expect(await verifyPassword("wrong", h)).toBe(false);
  });
  it("битая строка хеша → false", async () => {
    expect(await verifyPassword("x", "не-хеш")).toBe(false);
  });
});

describe("AuthService — регистрация", () => {
  it("первый пользователь — админ, второй — нет", async () => {
    const { auth } = svc();
    const first = await auth.createUser("owner", "password1");
    const second = await auth.createUser("tester", "password2");
    expect(first.isAdmin).toBe(true);
    expect(second.isAdmin).toBe(false);
  });
  it("HARNESS_ADMIN_USER делает названного админом", async () => {
    const { auth } = svc(() => new Date(), "boss");
    await auth.createUser("someone", "password1"); // первый — тоже админ
    const boss = await auth.createUser("boss", "password2");
    expect(boss.isAdmin).toBe(true);
  });
  it("дубликат логина → ошибка", async () => {
    const { auth } = svc();
    await auth.createUser("alice", "password1");
    await expect(auth.createUser("alice", "password2")).rejects.toThrow();
  });
  it("роль решается атомарно: два параллельных первых → ровно один админ", async () => {
    const { auth } = svc();
    const [a, b] = await Promise.all([auth.createUser("u1", "password1"), auth.createUser("u2", "password2")]);
    expect([a.isAdmin, b.isAdmin].filter(Boolean)).toHaveLength(1);
  });
  it("короткий пароль/логин → ошибка", async () => {
    const { auth } = svc();
    await expect(auth.createUser("a", "password")).rejects.toThrow();
    await expect(auth.createUser("alice", "123")).rejects.toThrow();
  });
});

describe("AuthService — логин и сессии", () => {
  it("verifyLogin: верный пароль → row, неверный → null", async () => {
    const { auth } = svc();
    const u = await auth.createUser("alice", "password1");
    expect((await auth.verifyLogin("alice", "password1"))?.id).toBe(u.id);
    expect(await auth.verifyLogin("alice", "wrong")).toBeNull();
    expect(await auth.verifyLogin("ghost", "password1")).toBeNull();
  });

  it("сессия резолвится, отзыв закрывает доступ", async () => {
    const { auth } = svc();
    const u = await auth.createUser("alice", "password1");
    const { token } = auth.createSession(u.id);
    expect(auth.resolveSession(token)?.username).toBe("alice");
    auth.revokeSession(token);
    expect(auth.resolveSession(token)).toBeNull();
  });

  it("истёкшая сессия → null", async () => {
    let t = new Date("2026-01-01T00:00:00Z").getTime();
    const { auth } = svc(() => new Date(t));
    const u = await auth.createUser("alice", "password1");
    const { token } = auth.createSession(u.id);
    t += 31 * 24 * 60 * 60 * 1000; // +31 день (TTL 30)
    expect(auth.resolveSession(token)).toBeNull();
  });
});
