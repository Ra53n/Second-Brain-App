// auth.ts — bearer-авторизация (порт из manager-agent). Сравнение токена —
// постоянного времени (защита от timing-атак).

import { timingSafeEqual } from "node:crypto";
import type { FastifyReply, FastifyRequest } from "fastify";
import { UnauthorizedError } from "../domain/errors.js";

export function safeEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ba.length !== bb.length) return false;
  return timingSafeEqual(ba, bb);
}

/** Возвращает preHandler-хук Fastify, проверяющий bearer-токен. */
export function bearerAuth(expectedToken: string) {
  return async (req: FastifyRequest, _reply: FastifyReply): Promise<void> => {
    const header = req.headers["authorization"];
    if (!header || !header.startsWith("Bearer ")) {
      throw new UnauthorizedError("Требуется заголовок Authorization: Bearer <token>.");
    }
    const presented = header.slice("Bearer ".length).trim();
    if (!expectedToken || !safeEqual(presented, expectedToken)) {
      throw new UnauthorizedError("Неверный токен доступа.");
    }
  };
}
