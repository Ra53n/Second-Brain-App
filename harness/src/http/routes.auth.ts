// routes.auth.ts — публичные маршруты регистрации/входа/выхода/«кто я»
// (порт support, path=/chat). Регистрация открытая; первый пользователь — админ.

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { UnauthorizedError, ValidationError } from "../domain/errors.js";
import { SESSION_COOKIE } from "./authMiddleware.js";

const SESSION_MAX_AGE_SEC = 30 * 24 * 60 * 60;

const credsBody = {
  type: "object",
  required: ["username", "password"],
  properties: { username: { type: "string" }, password: { type: "string" } },
} as const;

function cookieOptions(maxAgeSec: number) {
  return {
    httpOnly: true,
    secure: true, // за Caddy всегда HTTPS
    sameSite: "strict" as const,
    path: "/chat",
    signed: true,
    maxAge: maxAgeSec,
  };
}

/** CSRF-страховка: если запрос из браузера (есть Origin), его host должен совпасть. */
export function checkOrigin(req: { headers: Record<string, unknown> }): void {
  const origin = req.headers["origin"] as string | undefined;
  if (!origin) return;
  const host = req.headers["host"] as string | undefined;
  try {
    if (new URL(origin).host !== host) throw new ValidationError("Origin не совпадает с хостом.");
  } catch (e) {
    if (e instanceof ValidationError) throw e;
    throw new ValidationError("Некорректный Origin.");
  }
}

export function registerAuthRoutes(app: FastifyInstance, ctx: AppContext): void {
  const authLimit = { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } };

  app.post<{ Body: { username: string; password: string } }>(
    "/chat/auth/register",
    { schema: { body: credsBody }, ...authLimit },
    async (req, reply) => {
      checkOrigin(req);
      const user = await ctx.auth.createUser(req.body.username, req.body.password);
      const { token } = ctx.auth.createSession(user.id);
      reply.setCookie(SESSION_COOKIE, token, cookieOptions(SESSION_MAX_AGE_SEC));
      reply.status(201);
      return { user };
    },
  );

  app.post<{ Body: { username: string; password: string } }>(
    "/chat/auth/login",
    { schema: { body: credsBody }, ...authLimit },
    async (req, reply) => {
      checkOrigin(req);
      const row = await ctx.auth.verifyLogin(req.body.username, req.body.password);
      if (!row) throw new UnauthorizedError("Неверный логин или пароль.");
      const { token } = ctx.auth.createSession(row.id);
      reply.setCookie(SESSION_COOKIE, token, cookieOptions(SESSION_MAX_AGE_SEC));
      return { user: { id: row.id, username: row.username, isAdmin: row.is_admin === 1, createdAt: row.created_at } };
    },
  );

  app.post("/chat/auth/logout", async (req, reply) => {
    checkOrigin(req);
    const token = req.cookies?.[SESSION_COOKIE];
    if (token) {
      const unsigned = req.unsignCookie(token);
      if (unsigned.valid && unsigned.value) ctx.auth.revokeSession(unsigned.value);
    }
    reply.clearCookie(SESSION_COOKIE, { path: "/chat" });
    return { ok: true };
  });

  app.get("/chat/auth/me", async (req) => {
    const features = { webSearch: ctx.webSearchEnabled };
    const token = req.cookies?.[SESSION_COOKIE];
    if (!token) return { user: null, features };
    const unsigned = req.unsignCookie(token);
    if (!unsigned.valid || !unsigned.value) return { user: null, features };
    return { user: ctx.auth.resolveSession(unsigned.value), features };
  });
}
