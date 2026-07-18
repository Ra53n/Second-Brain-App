// index.ts — точка входа: bootstrap-конфиг, БД, сервисы, авто-регистрация
// CRM-MCP-сервера, HTTP-сервер. Слушает строго на 127.0.0.1 (наружу — только
// через Caddy /support/*). Корректное завершение по SIGTERM/SIGINT.

import pino from "pino";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { loadConfig } from "./config.js";
import { fastifyLoggerOptions } from "./logger.js";
import { openDb } from "./store/db.js";
import { SettingsRepo } from "./store/settingsRepo.js";
import { SettingsService } from "./settings/settingsService.js";
import { McpServersRepo } from "./store/mcpServersRepo.js";
import { McpHostImpl } from "./mcp/mcpHost.js";
import { OllamaClient } from "./llm/ollamaClient.js";
import { ChatRepo } from "./store/chatRepo.js";
import { UsersRepo } from "./store/usersRepo.js";
import { AuthService } from "./auth/authService.js";
import { KbRepo } from "./store/kbRepo.js";
import { KbIndexer } from "./rag/indexer.js";
import { OllamaEmbedder } from "./rag/embedder.js";
import { CrmStore } from "./crm/crmStore.js";
import { SupportChatService } from "./chat/supportChatService.js";
import { buildApp } from "./http/app.js";
import type { AppContext } from "./http/context.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const logger = pino(fastifyLoggerOptions(config.logLevel));

  const db = openDb(config.dbPath);
  const settings = new SettingsService(new SettingsRepo(db));
  const mcpServersRepo = new McpServersRepo(db);

  // Первый старт: регистрируем встроенный CRM-MCP-сервер (dist/mcp/crm-server.js
  // этого же деплоя). Админ может править/выключать его в админке.
  if (mcpServersRepo.count() === 0) {
    // index.js лежит в корне dist/ → его каталог и есть distDir.
    const distDir = dirname(fileURLToPath(import.meta.url));
    mcpServersRepo.replaceAll(
      [
        {
          id: "crm-builtin",
          name: "crm",
          command: process.execPath, // тот же node, которым запущен сервис
          args: [join(distDir, "mcp", "crm-server.js")],
          env: { CRM_DATA_DIR: config.crmDir },
          enabled: true,
        },
      ],
      new Date().toISOString(),
    );
    logger.info({}, "зарегистрирован встроенный CRM-MCP-сервер");
  }

  const mcpHost = new McpHostImpl(undefined, logger);
  await mcpHost.refresh(mcpServersRepo.list());

  const ollama = new OllamaClient({ baseUrl: config.ollamaUrl });
  const kbRepo = new KbRepo(db);
  const kbIndexer = new KbIndexer(kbRepo, config.kbDir, () => new Date(), logger);
  const crm = new CrmStore(config.crmDir);
  const chatRepo = new ChatRepo(db);
  const auth = new AuthService(new UsersRepo(db), () => new Date());
  const chat = new SupportChatService({ settings, ollama, kbRepo, crm, mcpHost });

  const ctx: AppContext = {
    settings,
    mcpServersRepo,
    mcpHost,
    ollama,
    chat,
    chatRepo,
    auth,
    kbRepo,
    kbIndexer,
    embedderFactory: (s) => new OllamaEmbedder(ollama, s.embedModel),
    crm,
    kbDir: config.kbDir,
    apiToken: config.apiToken,
    sessionSecret: config.sessionSecret,
    now: () => new Date(),
  };

  const app = buildApp(ctx, { logger });
  await app.listen({ host: config.host, port: config.port });
  logger.info({ host: config.host, port: config.port }, "support-assistant запущен");

  // Прогрев локальной модели — строго fire-and-forget (холодная загрузка
  // десятки секунд, блокировать старт нельзя — systemd-таймауты).
  const s = settings.getInternal();
  if (s.provider === "ollama") {
    void ollama.warmup(s.localModel).catch((e) => {
      logger.warn({ err: (e as Error).message }, "прогрев модели не удался (не критично)");
    });
  }

  const shutdown = async (signal: string) => {
    logger.info({ signal }, "останавливаюсь");
    try {
      await app.close();
      await mcpHost.close();
      db.close();
    } finally {
      process.exit(0);
    }
  };
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
  process.on("SIGINT", () => void shutdown("SIGINT"));
}

main().catch((err) => {
  // Падаем с понятным сообщением — systemd покажет его в journalctl.
  console.error(`[support-assistant] фатальная ошибка запуска: ${(err as Error).message}`);
  process.exit(1);
});
