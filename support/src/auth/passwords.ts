// passwords.ts — хеширование паролей на встроенном node:crypto.scrypt
// (порт из manager-agent, без изменений).
//
// Без нативных зависимостей (argon2/bcrypt): scrypt входит в Node, устойчив к
// перебору по памяти. Формат хранимой строки: "scrypt$N$salt_hex$hash_hex".
// Сравнение — постоянного времени (timingSafeEqual).

import { randomBytes, scrypt, timingSafeEqual } from "node:crypto";

const SCRYPT_N = 16384; // cost (2^14) — баланс безопасность/скорость на слабом VPS
const KEY_LEN = 32;
const SALT_LEN = 16;

function scryptAsync(password: string, salt: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, KEY_LEN, { N: SCRYPT_N }, (err, derived) => {
      if (err) reject(err);
      else resolve(derived);
    });
  });
}

/** Возвращает строку "scrypt$N$salt$hash" для хранения в БД. */
export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(SALT_LEN);
  const derived = await scryptAsync(password, salt);
  return `scrypt$${SCRYPT_N}$${salt.toString("hex")}$${derived.toString("hex")}`;
}

/** Проверяет пароль против хранимой строки (constant-time). */
export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const parts = stored.split("$");
  if (parts.length !== 4 || parts[0] !== "scrypt") return false;
  const n = Number.parseInt(parts[1]!, 10);
  const salt = Buffer.from(parts[2]!, "hex");
  const expected = Buffer.from(parts[3]!, "hex");
  if (!Number.isInteger(n) || salt.length === 0 || expected.length === 0) return false;
  const derived = await new Promise<Buffer>((resolve, reject) => {
    scrypt(password, salt, expected.length, { N: n }, (err, d) => (err ? reject(err) : resolve(d)));
  });
  if (derived.length !== expected.length) return false;
  return timingSafeEqual(derived, expected);
}
