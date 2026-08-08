// index.ts — точка входа: конфиг → БД → репозитории → инструменты → HTTP.

import { pino } from "pino";
import { loadConfig, ConfigError } from "./config.js";
import { fastifyLoggerOptions } from "./logger.js";
import { openDb } from "./store/db.js";
import { SettingsRepo } from "./store/settingsRepo.js";
import { SessionRepo } from "./store/sessionRepo.js";
import { AttemptRepo } from "./store/attemptRepo.js";
import { FlagsRepo } from "./lab/flags.js";
import { LabChatService } from "./chat/labChatService.js";
import { createWebSearchTool } from "./tools/webSearch.js";
import { createFetchUrlTool } from "./tools/fetchUrl.js";
import { createCorpTools } from "./tools/corpDocs.js";
import { hashPassword } from "./auth/passwords.js";
import { buildApp } from "./http/app.js";
import type { LabTool } from "./tools/registry.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const db = openDb(config.dbPath);

  const settingsRepo = new SettingsRepo(db);
  const sessionRepo = new SessionRepo(db);
  const attemptRepo = new AttemptRepo(db);
  const flagsRepo = new FlagsRepo(db);
  flagsRepo.ensure();

  // Код доступа из env — только первичный посев: дальше он меняется из админки
  // и env уже не перечитывается (иначе правка в UI откатывалась бы рестартом).
  if (!settingsRepo.get().accessCodeHash && config.accessCode) {
    settingsRepo.update({ accessCodeHash: await hashPassword(config.accessCode) });
  }

  const tools: LabTool[] = [
    createWebSearchTool({
      config: () => {
        const s = settingsRepo.get();
        return { provider: s.searchProvider, apiKey: s.searchApiKey };
      },
    }),
    createFetchUrlTool(),
    ...createCorpTools({
      dir: config.corpDir,
      flags: () => Object.fromEntries(flagsRepo.list().map((f) => [f.key, f.value])),
    }),
  ];

  // Один pino на сервис: и Fastify, и сервисы вне HTTP-контекста пишут в него,
  // с общим redaction секретов (см. fastifyLoggerOptions).
  const logger = pino(fastifyLoggerOptions(config.logLevel));

  const app = buildApp(
    {
      settingsRepo,
      sessionRepo,
      attemptRepo,
      flagsRepo,
      chat: new LabChatService({
        settingsRepo,
        flagsRepo,
        sessionRepo,
        attemptRepo,
        tools,
        logger,
      }),
      apiToken: config.apiToken,
      sessionSecret: config.sessionSecret,
      now: () => new Date(),
    },
    { logger },
  );

  logger.info({ port: config.port, corpDir: config.corpDir }, "agent-lab запускается");

  const shutdown = async (signal: string) => {
    app.log.info({ signal }, "остановка");
    await app.close().catch(() => undefined);
    db.close();
    process.exit(0);
  };
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
  process.on("SIGINT", () => void shutdown("SIGINT"));

  await app.listen({ host: config.host, port: config.port });
}

main().catch((e) => {
  if (e instanceof ConfigError) {
    process.stderr.write(`Ошибка конфигурации: ${e.message}\n`);
    process.exit(2);
  }
  process.stderr.write(`Не удалось запустить agent-lab: ${(e as Error).stack ?? e}\n`);
  process.exit(1);
});
