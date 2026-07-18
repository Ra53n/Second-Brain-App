// routes.auth.ts — публичные маршруты входа/выхода/«кто я» (порт из
// manager-agent, path=/support). Admin-CRUD пользователей — в routes.admin.ts.

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { UnauthorizedError, ValidationError } from "../domain/errors.js";
import { SESSION_COOKIE } from "./authMiddleware.js";
import { loginBody } from "./schemas.js";

const SESSION_MAX_AGE_SEC = 30 * 24 * 60 * 60; // 30 дней

function cookieOptions(maxAgeSec: number) {
  return {
    httpOnly: true,
    secure: true, // за Caddy всегда HTTPS
    sameSite: "strict" as const,
    path: "/support",
    signed: true,
    maxAge: maxAgeSec,
  };
}

/** CSRF-страховка: если запрос из браузера (есть Origin), его host должен совпасть. */
export function checkOrigin(req: { headers: Record<string, unknown> }): void {
  const origin = req.headers["origin"] as string | undefined;
  if (!origin) return; // curl/скрипты — без Origin, пропускаем
  const host = req.headers["host"] as string | undefined;
  try {
    if (new URL(origin).host !== host) {
      throw new ValidationError("Origin не совпадает с хостом.");
    }
  } catch (e) {
    if (e instanceof ValidationError) throw e;
    throw new ValidationError("Некорректный Origin.");
  }
}

/** Публичные auth-маршруты (регистрируются в корневом скоупе, вне bearer). */
export function registerAuthRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.post<{ Body: { username: string; password: string } }>(
    "/support/auth/login",
    {
      schema: { body: loginBody },
      config: { rateLimit: { max: 10, timeWindow: "1 minute" } },
    },
    async (req, reply) => {
      checkOrigin(req);
      const user = await ctx.auth.verifyLogin(req.body.username, req.body.password);
      if (!user) throw new UnauthorizedError("Неверный логин или пароль.");
      const { token } = ctx.auth.createSession(user.id);
      reply.setCookie(SESSION_COOKIE, token, cookieOptions(SESSION_MAX_AGE_SEC));
      return {
        user: {
          id: user.id,
          username: user.username,
          email: user.email,
          isAdmin: user.is_admin === 1,
        },
      };
    },
  );

  app.post("/support/auth/logout", async (req, reply) => {
    checkOrigin(req);
    const token = req.cookies?.[SESSION_COOKIE];
    if (token) {
      const unsigned = req.unsignCookie(token);
      if (unsigned.valid && unsigned.value) ctx.auth.revokeSession(unsigned.value);
    }
    reply.clearCookie(SESSION_COOKIE, { path: "/support" });
    return { ok: true };
  });

  app.get("/support/auth/me", async (req) => {
    const token = req.cookies?.[SESSION_COOKIE];
    if (!token) return { user: null };
    const unsigned = req.unsignCookie(token);
    if (!unsigned.valid || !unsigned.value) return { user: null };
    const user = ctx.auth.resolveSession(unsigned.value);
    return { user };
  });
}
