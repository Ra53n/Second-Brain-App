// authMiddleware.ts — комбинированная авторизация (порт из manager-agent +
// новый requireAdmin для админки в браузере).
//
//   • requireUserOrAdmin — bearer <SUPPORT_API_TOKEN> (admin-пространство,
//     user=null) ИЛИ cookie-сессия (обычный пользователь). Чат-эндпоинты.
//   • requireAdmin — bearer ИЛИ cookie-сессия С is_admin=1. Админ-эндпоинты
//     (настройки/KB/CRM/MCP/пользователи): работают и из скриптов, и из SPA.

import type { FastifyReply, FastifyRequest } from "fastify";
import { ForbiddenError, UnauthorizedError } from "../domain/errors.js";
import type { AuthService } from "../auth/authService.js";
import type { PublicUser } from "../store/usersRepo.js";
import { safeEqual } from "./auth.js";

export const SESSION_COOKIE = "sid";

/** Кто выполняет запрос: admin (bearer) либо конкретный пользователь (cookie). */
export interface Principal {
  isAdmin: boolean;
  user: PublicUser | null; // null для admin-bearer (admin-пространство)
}

declare module "fastify" {
  interface FastifyRequest {
    principal?: Principal;
  }
}

/** Владелец чатов текущего принципала: user.id, либо null для admin-bearer. */
export function ownerScope(principal: Principal): string | null {
  return principal.user ? principal.user.id : null;
}

/** Разбирает принципала из запроса; null — ни bearer, ни валидной cookie. */
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

/** preHandler: bearer ЛИБО cookie-сессия. Кладёт req.principal. */
export function requireUserOrAdmin(apiToken: string, auth: AuthService) {
  return async (req: FastifyRequest, _reply: FastifyReply): Promise<void> => {
    const p = resolvePrincipal(req, apiToken, auth);
    if (p === "bad_token") throw new UnauthorizedError("Неверный токен доступа.");
    if (!p) throw new UnauthorizedError("Требуется вход или токен доступа.");
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
