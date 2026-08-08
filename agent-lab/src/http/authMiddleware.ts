// authMiddleware.ts — два независимых доступа.
//
//  • Атакующий — cookie-сессия, полученная в обмен на код доступа.
//  • Владелец — admin bearer-токен из /etc/agent-lab.env.
// Пересечений нет: атакующий никогда не получает admin-скоуп, поэтому журнал
// попыток и значения флагов ему недоступны даже при полном взломе промпта.

import { timingSafeEqual } from "node:crypto";
import type { FastifyReply, FastifyRequest } from "fastify";
import { UnauthorizedError } from "../domain/errors.js";
import type { AppContext } from "./context.js";
import type { LabSession } from "../domain/types.js";

export const SESSION_COOKIE = "lab_session";

declare module "fastify" {
  interface FastifyRequest {
    labSession?: LabSession;
  }
}

/** Сравнение токенов постоянного времени (длины могут не совпадать). */
function tokensEqual(a: string, b: string): boolean {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

export function isAdmin(req: FastifyRequest, ctx: AppContext): boolean {
  const header = req.headers.authorization ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match?.[1]) return false;
  return tokensEqual(match[1].trim(), ctx.apiToken);
}

export function requireAdmin(ctx: AppContext) {
  return async (req: FastifyRequest, _reply: FastifyReply) => {
    if (!isAdmin(req, ctx)) throw new UnauthorizedError("Нужен admin-токен лаборатории");
  };
}

export function requireSession(ctx: AppContext) {
  return async (req: FastifyRequest, _reply: FastifyReply) => {
    const token = req.cookies?.[SESSION_COOKIE];
    const session = token ? ctx.sessionRepo.touch(token) : null;
    if (!session) throw new UnauthorizedError("Нужен код доступа");
    req.labSession = session;
  };
}
