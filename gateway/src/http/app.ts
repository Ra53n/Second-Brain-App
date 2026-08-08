// app.ts — сборка Fastify-приложения: единый обработчик ошибок, публичный
// /gw/health и чат (за rate-limit), админка по bearer-токену.

import Fastify, { type FastifyInstance, type FastifyServerOptions } from "fastify";
import rateLimit from "@fastify/rate-limit";
import type { AppContext } from "./context.js";
import { AppError } from "../domain/errors.js";
import { registerGatewayRoutes } from "./routes.gw.js";
import { registerWebRoutes } from "./routes.web.js";

export const GW_VERSION = "0.1.0";

export interface BuildAppOptions {
  logger?: FastifyServerOptions["logger"];
}

export async function buildApp(ctx: AppContext, opts: BuildAppOptions = {}): Promise<FastifyInstance> {
  // trustProxy: за Caddy реальный IP приходит в X-Forwarded-For (нужен rate-limit'у).
  const app = Fastify({ logger: opts.logger ?? false, trustProxy: true });

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.httpStatus).send({
        error: { code: err.code, message: err.message, details: err.details ?? null },
      });
    }
    const anyErr = err as { validation?: unknown; statusCode?: number };
    if (anyErr.validation) {
      return reply.status(400).send({
        error: { code: "validation_error", message: err.message, details: anyErr.validation ?? null },
      });
    }
    req.log.error({ err }, "необработанная ошибка");
    return reply.status(500).send({
      error: { code: "internal", message: "Внутренняя ошибка сервера", details: null },
    });
  });

  // await обязателен: onRoute-хук rate-limit должен встать ДО регистрации
  // маршрутов, иначе per-route лимиты к ним не применяются.
  // errorResponseBuilder возвращает AppError(busy,429): плагин прокидывает его
  // в setErrorHandler, который отдаёт 429 в том же конверте {error:{code,message}},
  // что и остальные ошибки (по умолчанию плагин шлёт свой формат мимо handler).
  await app.register(rateLimit, {
    global: false,
    errorResponseBuilder: (_req, ctx) =>
      new AppError("busy", `Слишком часто. Лимит ${ctx.max}/мин. Подожди немного.`, 429) as unknown as Record<string, unknown>,
  });

  app.get("/gw/health", async () => ({
    status: "ok",
    version: GW_VERSION,
    uptime: Math.round(process.uptime()),
  }));

  registerWebRoutes(app);
  registerGatewayRoutes(app, ctx);

  return app;
}
