// index.ts — точка входа: конфиг → БД → репозитории → сервис → HTTP listen.

import { loadConfig } from "./config.js";
import { fastifyLoggerOptions } from "./logger.js";
import { openDb } from "./store/db.js";
import { SettingsRepo } from "./store/settingsRepo.js";
import { AuditRepo } from "./store/auditRepo.js";
import { GatewayService } from "./chat/gatewayService.js";
import { buildApp } from "./http/app.js";
import type { AppContext } from "./http/context.js";

async function main(): Promise<void> {
  const cfg = loadConfig();
  const db = openDb(cfg.dbPath);

  const settingsRepo = new SettingsRepo(db);
  const auditRepo = new AuditRepo(db);
  const gateway = new GatewayService(settingsRepo, auditRepo);

  const ctx: AppContext = { settingsRepo, auditRepo, gateway, apiToken: cfg.apiToken };
  const app = await buildApp(ctx, { logger: fastifyLoggerOptions(cfg.logLevel) });

  await app.listen({ host: cfg.host, port: cfg.port });
}

main().catch((err) => {
  // Единственный допустимый вывод: фатальная ошибка старта до готовности логгера.
  process.stderr.write(`[gateway] фатальный сбой старта: ${(err as Error).message}\n`);
  process.exit(1);
});
