// app.ts — сборка Fastify-приложения: единый обработчик ошибок, публичные
// /support/health + SPA + auth-маршруты, авторизованный чат и admin-зона.

import Fastify, { type FastifyInstance, type FastifyServerOptions } from "fastify";
import cookie from "@fastify/cookie";
import rateLimit from "@fastify/rate-limit";
import type { AppContext } from "./context.js";
import { AppError } from "../domain/errors.js";
import { registerAuthRoutes } from "./routes.auth.js";
import { registerChatRoutes } from "./routes.chat.js";
import { registerAdminRoutes } from "./routes.admin.js";
import { registerWebRoutes } from "./routes.web.js";

export const SUPPORT_VERSION = "0.1.0";

export interface BuildAppOptions {
  /** Логгер Fastify: pino-инстанс, объект опций или false (выкл, по умолчанию). */
  logger?: FastifyServerOptions["logger"];
}

export function buildApp(ctx: AppContext, opts: BuildAppOptions = {}): FastifyInstance {
  // trustProxy: за Caddy реальный IP приходит в X-Forwarded-For (нужно rate-limit'у).
  const app = Fastify({ logger: opts.logger ?? false, trustProxy: true });

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.httpStatus).send({
        error: { code: err.code, message: err.message, details: err.details ?? null },
      });
    }
    // Ошибка валидации схемы Fastify/ajv.
    const anyErr = err as { validation?: unknown; statusCode?: number };
    if (anyErr.validation) {
      return reply.status(400).send({
        error: {
          code: "validation_error",
          message: err.message,
          details: anyErr.validation ?? null,
        },
      });
    }
    req.log.error({ err }, "необработанная ошибка");
    return reply.status(500).send({
      error: { code: "internal", message: "Внутренняя ошибка сервера", details: null },
    });
  });

  // Cookie-подпись (веб-сессии) + rate-limit (глобально выключен, включается
  // на конкретных маршрутах вроде логина через config.rateLimit).
  app.register(cookie, { secret: ctx.sessionSecret });
  app.register(rateLimit, { global: false });

  // Публичный liveness — без авторизации (для Caddy/systemd/смоук-проверок).
  app.get("/support/health", async () => ({
    status: "ok",
    version: SUPPORT_VERSION,
    uptime: Math.round(process.uptime()),
  }));

  // Публичные: SPA и вход/выход/«кто я».
  registerWebRoutes(app, ctx);
  registerAuthRoutes(app, ctx);

  // Чат (bearer=admin ИЛИ cookie=пользователь) и admin-зона — свои скоупы.
  registerChatRoutes(app, ctx);
  registerAdminRoutes(app, ctx);

  return app;
}
