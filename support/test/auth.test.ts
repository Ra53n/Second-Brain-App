// Тесты авторизации: scrypt, сессии, TTL, requireAdmin.

import { describe, expect, it } from "vitest";
import { hashPassword, verifyPassword } from "../src/auth/passwords.js";
import { AuthService } from "../src/auth/authService.js";
import { UsersRepo } from "../src/store/usersRepo.js";
import { openDb } from "../src/store/db.js";
import { ConflictError, ValidationError } from "../src/domain/errors.js";

function makeAuth(now = () => new Date("2026-07-18T10:00:00Z")) {
  const db = openDb(":memory:");
  return { auth: new AuthService(new UsersRepo(db), now), db };
}

describe("passwords", () => {
  it("hash/verify round-trip; чужой пароль не проходит", async () => {
    const stored = await hashPassword("secret123");
    expect(stored.startsWith("scrypt$")).toBe(true);
    expect(await verifyPassword("secret123", stored)).toBe(true);
    expect(await verifyPassword("wrong", stored)).toBe(false);
  });

  it("битая строка хранения → false", async () => {
    expect(await verifyPassword("x", "мусор")).toBe(false);
    expect(await verifyPassword("x", "bcrypt$1$aa$bb")).toBe(false);
  });
});

describe("AuthService", () => {
  it("создание: валидации и уникальность; email нормализуется", async () => {
    const { auth } = makeAuth();
    await expect(auth.createUser("a", "longpass")).rejects.toThrow(ValidationError);
    await expect(auth.createUser("user", "123")).rejects.toThrow(ValidationError);
    const u = await auth.createUser("maria", "secret123", { email: " Maria@Example.COM " });
    expect(u.email).toBe("maria@example.com");
    await expect(auth.createUser("maria", "secret123")).rejects.toThrow(ConflictError);
  });

  it("логин: верный пароль → пользователь, неверный → null", async () => {
    const { auth } = makeAuth();
    await auth.createUser("maria", "secret123");
    expect(await auth.verifyLogin("maria", "secret123")).not.toBeNull();
    expect(await auth.verifyLogin("maria", "wrong")).toBeNull();
    expect(await auth.verifyLogin("ghost", "secret123")).toBeNull();
  });

  it("сессия: создаётся, резолвится, отзывается", async () => {
    const { auth } = makeAuth();
    const u = await auth.createUser("maria", "secret123");
    const { token } = auth.createSession(u.id);
    expect(auth.resolveSession(token)?.username).toBe("maria");
    auth.revokeSession(token);
    expect(auth.resolveSession(token)).toBeNull();
  });

  it("истёкшая сессия → null и удаляется", async () => {
    let nowMs = Date.parse("2026-07-18T10:00:00Z");
    const { auth } = makeAuth(() => new Date(nowMs));
    const u = await auth.createUser("maria", "secret123");
    const { token } = auth.createSession(u.id);
    nowMs += 31 * 24 * 60 * 60 * 1000; // 31 день
    expect(auth.resolveSession(token)).toBeNull();
  });

  it("удаление пользователя каскадом отзывает сессии", async () => {
    const { auth } = makeAuth();
    const u = await auth.createUser("maria", "secret123");
    const { token } = auth.createSession(u.id);
    auth.deleteUser(u.id);
    expect(auth.resolveSession(token)).toBeNull();
  });
});
