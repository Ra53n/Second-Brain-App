// authMiddleware.ts — admin-доступ по bearer-токену. Порт gateway.

import { timingSafeEqual } from "node:crypto";
import type { FastifyReply, FastifyRequest } from "fastify";
import { UnauthorizedError } from "../domain/errors.js";
import type { AppContext } from "./context.js";

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
    if (!isAdmin(req, ctx)) throw new UnauthorizedError("Нужен admin-токен harness");
  };
}
