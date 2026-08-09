// authMiddleware.ts — комбинированная авторизация (порт support):
//   • requireUser  — cookie-сессия конкретного пользователя (чат-эндпоинты).
//   • requireAdmin — bearer HARNESS_API_TOKEN (break-glass) ИЛИ cookie-сессия
//     с is_admin=1 (админ-эндпоинты: логи всех пользователей, алерты).

import type { FastifyReply, FastifyRequest } from "fastify";
import { ForbiddenError, UnauthorizedError } from "../domain/errors.js";
import type { AuthService } from "../auth/authService.js";
import type { PublicUser } from "../store/usersRepo.js";
import { safeEqual } from "./auth.js";

export const SESSION_COOKIE = "sid";

/** Кто выполняет запрос: admin (bearer, user=null) либо конкретный пользователь. */
export interface Principal {
  isAdmin: boolean;
  user: PublicUser | null;
}

declare module "fastify" {
  interface FastifyRequest {
    principal?: Principal;
  }
}

/** Разбирает принципала: bearer-токен или cookie-сессия. */
function resolvePrincipal(
  req: FastifyRequest,
  apiToken: string,
  auth: AuthService,
): Principal | null | "bad_token" {
  const header = req.headers["authorization"];
  if (header && header.startsWith("Bearer ")) {
    const presented = header.slice("Bearer ".length).trim();
    if (apiToken && safeEqual(presented, apiToken)) return { isAdmin: true, user: null };
    return "bad_token";
  }
  const signed = req.cookies?.[SESSION_COOKIE];
  if (signed) {
    const unsigned = req.unsignCookie(signed);
    if (unsigned.valid && unsigned.value) {
      const user = auth.resolveSession(unsigned.value);
      if (user) return { isAdmin: user.isAdmin, user };
    }
  }
  return null;
}

/** preHandler: требует cookie-сессию реального пользователя. */
export function requireUser(apiToken: string, auth: AuthService) {
  return async (req: FastifyRequest, _reply: FastifyReply): Promise<void> => {
    const p = resolvePrincipal(req, apiToken, auth);
    if (p === "bad_token") throw new UnauthorizedError("Неверный токен доступа.");
    if (!p || !p.user) throw new UnauthorizedError("Требуется вход.");
    req.principal = p;
  };
}

/** preHandler: bearer ЛИБО cookie-сессия администратора (is_admin=1). */
export function requireAdmin(apiToken: string, auth: AuthService) {
  return async (req: FastifyRequest, _reply: FastifyReply): Promise<void> => {
    const p = resolvePrincipal(req, apiToken, auth);
    if (p === "bad_token") throw new UnauthorizedError("Неверный токен доступа.");
    if (!p) throw new UnauthorizedError("Требуется вход или токен доступа.");
    if (!p.isAdmin) throw new ForbiddenError("Доступно только администратору.");
    req.principal = p;
  };
}
