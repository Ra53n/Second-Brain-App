// app.ts — сборка Fastify-приложения: единый обработчик ошибок, публичные
// /lab/health и страницы, чат по коду доступа, админка по bearer-токену.

import Fastify, { type FastifyInstance, type FastifyServerOptions } from "fastify";
import cookie from "@fastify/cookie";
import rateLimit from "@fastify/rate-limit";
import type { AppContext } from "./context.js";
import { AppError } from "../domain/errors.js";
import { ConfigError } from "../config.js";
import { registerChatRoutes } from "./routes.chat.js";
import { registerAdminRoutes } from "./routes.admin.js";
import { registerWebRoutes } from "./routes.web.js";

export const LAB_VERSION = "0.1.0";

export interface BuildAppOptions {
  logger?: FastifyServerOptions["logger"];
}

export function buildApp(ctx: AppContext, opts: BuildAppOptions = {}): FastifyInstance {
  // trustProxy: за Caddy реальный IP приходит в X-Forwarded-For (нужен rate-limit'у).
  const app = Fastify({ logger: opts.logger ?? false, trustProxy: true });

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.httpStatus).send({
        error: { code: err.code, message: err.message, details: err.details ?? null },
      });
    }
    if (err instanceof ConfigError) {
      return reply.status(503).send({ error: { code: "config_error", message: err.message, details: null } });
    }
    const anyErr = err as { validation?: unknown; statusCode?: number };
    if (anyErr.validation) {
      return reply.status(400).send({
        error: { code: "validation_error", message: err.message, details: anyErr.validation ?? null },
      });
    }
    if (anyErr.statusCode === 429) {
      return reply.status(429).send({
        error: { code: "busy", message: "Слишком часто. Подожди немного.", details: null },
      });
    }
    req.log.error({ err }, "необработанная ошибка");
    return reply.status(500).send({
      error: { code: "internal", message: "Внутренняя ошибка сервера", details: null },
    });
  });

  app.register(cookie, { secret: ctx.sessionSecret });
  app.register(rateLimit, { global: false });

  app.get("/lab/health", async () => ({
    status: "ok",
    version: LAB_VERSION,
    uptime: Math.round(process.uptime()),
  }));

  registerWebRoutes(app);
  registerChatRoutes(app, ctx);
  registerAdminRoutes(app, ctx);

  return app;
}
