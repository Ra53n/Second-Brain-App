// routes.web.ts — статические страницы. Админка отдаётся всем: без токена она
// пустая, а токен проверяется на каждом /lab/admin/* запросе.

import type { FastifyInstance } from "fastify";
import { ADMIN_PAGE, CHAT_PAGE } from "../web/index.js";

export function registerWebRoutes(app: FastifyInstance): void {
  const html = (page: string) => async (_req: unknown, reply: { type: (t: string) => { send: (b: string) => unknown } }) =>
    reply.type("text/html; charset=utf-8").send(page);

  app.get("/lab", html(CHAT_PAGE));
  app.get("/lab/", html(CHAT_PAGE));
  app.get("/lab/admin", html(ADMIN_PAGE));
}
