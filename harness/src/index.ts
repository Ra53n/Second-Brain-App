// index.ts — точка входа: конфиг → БД → репозиторий → менеджер → HTTP listen.
// На старте зависшие pending-ответы → failed (в чате проще переотправить).

import { loadConfig } from "./config.js";
import { fastifyLoggerOptions } from "./logger.js";
import { openDb } from "./store/db.js";
import { ChatsRepo } from "./store/chatsRepo.js";
import { UsersRepo } from "./store/usersRepo.js";
import { AuthService } from "./auth/authService.js";
import { GatewayClient } from "./run/gwClient.js";
import { ChatManager } from "./run/chatManager.js";
import { buildApp } from "./http/app.js";
import { CHAT_VERSION } from "./http/version.js";
import type { AppContext, AgentConfigView } from "./http/context.js";
import { SECURITY_DIRECTIVE } from "./guard/security.js";

const MAX_ROUNDS = 4;
const HISTORY_WINDOW = 20;
const RATE_LIMIT_PER_MIN = 15;

async function main(): Promise<void> {
  const cfg = loadConfig();
  const db = openDb(cfg.dbPath);

  const repo = new ChatsRepo(db);
  const usersRepo = new UsersRepo(db);
  const auth = new AuthService(usersRepo, cfg.adminUser);
  const gateway = new GatewayClient(cfg.gwUrl);
  const manager = new ChatManager({ repo, gateway, canary: cfg.canary });

  const recovered = manager.recoverOnBoot();
  usersRepo.deleteExpiredSessions(new Date().toISOString());

  const configView = (): AgentConfigView => ({
    version: CHAT_VERSION,
    gwUrl: cfg.gwUrl,
    model: "(из настроек gateway /gw/admin)",
    loop: "генерация → проверка корректности → security review → результат (итерация при провале, лимит кругов)",
    modes: "Обычный (прямой ответ) · Execution Loop (каждое сообщение через loop)",
    maxRounds: MAX_ROUNDS,
    historyWindow: HISTORY_WINDOW,
    rateLimitPerMin: RATE_LIMIT_PER_MIN,
    canaryEnabled: cfg.canary.length > 0,
    // Превью слоя безопасности, который чат добавляет в каждый запрос.
    // Канарейка сюда не входит (добавляется на рантайме) — раскрытия нет.
    systemPromptPreview: SECURITY_DIRECTIVE,
  });

  const ctx: AppContext = {
    repo,
    manager,
    auth,
    apiToken: cfg.apiToken,
    sessionSecret: cfg.sessionSecret,
    configView,
  };
  const app = await buildApp(ctx, { logger: fastifyLoggerOptions(cfg.logLevel) });

  await app.listen({ host: cfg.host, port: cfg.port });
  if (recovered > 0) app.log.info(`старт: ${recovered} прерванных ответов помечены failed`);
}

main().catch((err) => {
  process.stderr.write(`[chat] фатальный сбой старта: ${(err as Error).message}\n`);
  process.exit(1);
});
