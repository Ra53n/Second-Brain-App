// routes.web.ts — отдача статических HTML-страниц (чат + админка).

import type { FastifyInstance } from "fastify";
import { CHAT_PAGE, ADMIN_PAGE } from "../web/index.js";

export function registerWebRoutes(app: FastifyInstance): void {
  const html = (page: string) => async (_req: unknown, reply: any) => {
    reply.header("content-type", "text/html; charset=utf-8").send(page);
  };
  app.get("/gw", html(CHAT_PAGE));
  app.get("/gw/", html(CHAT_PAGE));
  app.get("/gw/admin", html(ADMIN_PAGE));
}
