// app.ts — сборка Fastify: единый обработчик ошибок, публичный /chat/health,
// запуск прогонов (за rate-limit), админка по bearer. Порт gateway/http/app.ts.

import Fastify, { type FastifyInstance, type FastifyServerOptions } from "fastify";
import rateLimit from "@fastify/rate-limit";
import type { AppContext } from "./context.js";
import { AppError } from "../domain/errors.js";
import { registerRoutes } from "./routes.js";
import { registerWebRoutes } from "../web/index.js";
import { CHAT_VERSION } from "./version.js";

export interface BuildAppOptions {
  logger?: FastifyServerOptions["logger"];
}

export async function buildApp(ctx: AppContext, opts: BuildAppOptions = {}): Promise<FastifyInstance> {
  // trustProxy: 1 — доверяем ровно одному хопу (Caddy на 127.0.0.1). При true
  // req.ip брался бы из крайнего левого X-Forwarded-For, и атакующий ротацией
  // заголовка обходил бы per-IP rate-limit.
  const app = Fastify({ logger: opts.logger ?? false, trustProxy: 1 });

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.httpStatus).send({
        error: { code: err.code, message: err.message, details: err.details ?? null },
      });
    }
    const anyErr = err as { validation?: unknown };
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

  await app.register(rateLimit, {
    global: false,
    errorResponseBuilder: (_req, c) =>
      new AppError("busy", `Слишком часто. Лимит ${c.max}/мин. Подожди немного.`, 429) as unknown as Record<
        string,
        unknown
      >,
  });

  app.get("/chat/health", async () => ({
    status: "ok",
    version: CHAT_VERSION,
    uptime: Math.round(process.uptime()),
  }));

  registerWebRoutes(app);
  registerRoutes(app, ctx);

  return app;
}
