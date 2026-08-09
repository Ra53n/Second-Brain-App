// index.ts — точка входа: конфиг → БД → репозиторий → менеджер → HTTP listen.
// На старте зависшие running → paused (resume-able).

import { loadConfig } from "./config.js";
import { fastifyLoggerOptions } from "./logger.js";
import { openDb } from "./store/db.js";
import { RunsRepo } from "./store/runsRepo.js";
import { GatewayClient } from "./run/gwClient.js";
import { RunManager } from "./run/manager.js";
import { buildApp, CHAT_VERSION } from "./http/app.js";
import type { AppContext, AgentConfigView } from "./http/context.js";
import { SECURITY_DIRECTIVE } from "./guard/security.js";

const MAX_ROUNDS = 4;
const RATE_LIMIT_PER_MIN = 10;
const DAILY_LIMIT = 200;

async function main(): Promise<void> {
  const cfg = loadConfig();
  const db = openDb(cfg.dbPath);

  const repo = new RunsRepo(db);
  const gateway = new GatewayClient(cfg.gwUrl);
  const manager = new RunManager(
    { repo, gateway, canary: cfg.canary },
    { maxRounds: MAX_ROUNDS, rateLimitPerMin: RATE_LIMIT_PER_MIN, dailyLimit: DAILY_LIMIT },
  );

  const recovered = manager.recoverOnBoot();

  const configView = (): AgentConfigView => ({
    version: CHAT_VERSION,
    gwUrl: cfg.gwUrl,
    model: "(из настроек gateway /gw/admin)",
    loop: "генерация → проверка корректности → security review → результат (итерация при провале, лимит кругов)",
    maxRounds: MAX_ROUNDS,
    defaultSecure: true,
    rateLimitPerMin: RATE_LIMIT_PER_MIN,
    dailyLimit: DAILY_LIMIT,
    canaryEnabled: cfg.canary.length > 0,
    // Превью слоя безопасности, который чат добавляет в каждый запрос.
    // Канарейка сюда не входит (добавляется на рантайме) — раскрытия нет.
    systemPromptPreview: SECURITY_DIRECTIVE,
  });

  const ctx: AppContext = { repo, manager, apiToken: cfg.apiToken, configView };
  const app = await buildApp(ctx, { logger: fastifyLoggerOptions(cfg.logLevel) });

  await app.listen({ host: cfg.host, port: cfg.port });
  if (recovered > 0) app.log.info(`resume: поднято ${recovered} зависших прогонов в paused`);
}

main().catch((err) => {
  process.stderr.write(`[chat] фатальный сбой старта: ${(err as Error).message}\n`);
  process.exit(1);
});
