// routes.web.ts — раздача веб-интерфейса (SPA) публично, вне авторизации:
// браузер должен загрузить страницу без токена, а вход — по cookie-сессии.

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { INDEX_HTML } from "../web/index.js";

export function registerWebRoutes(app: FastifyInstance, _ctx: AppContext): void {
  const send = (reply: import("fastify").FastifyReply) =>
    reply.type("text/html; charset=utf-8").send(INDEX_HTML);
  // Открывается как https://<домен>/support/ (и /support без слэша).
  app.get("/support", async (_req, reply) => send(reply));
  app.get("/support/", async (_req, reply) => send(reply));
  app.get("/support/app", async (_req, reply) => send(reply));
}
