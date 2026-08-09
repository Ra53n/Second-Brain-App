// config.ts — bootstrap-конфигурация из окружения.
//
// В /etc/llm-harness.env лежит только bootstrap:
//   HARNESS_API_TOKEN — admin bearer-токен (админка, curl);
//   HARNESS_HOST/PORT — где слушает HTTP (127.0.0.1:3500);
//   HARNESS_DB_PATH   — путь к SQLite;
//   GW_URL            — базовый URL gateway (localhost на том же VPS);
//   HARNESS_CANARY    — секретная фраза-канарейка для детекта «взлома» промпта;
//   LOG_LEVEL         — уровень логов.
// LLM-ключа тут НЕТ — harness ходит только в gateway.

import { ConfigError } from "./domain/errors.js";

export interface BootstrapConfig {
  apiToken: string;
  sessionSecret: string;
  adminUser: string;
  host: string;
  port: number;
  dbPath: string;
  gwUrl: string;
  canary: string;
  logLevel: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): BootstrapConfig {
  const apiToken = (env.HARNESS_API_TOKEN ?? "").trim();
  if (!apiToken) {
    throw new ConfigError(
      "Не задан HARNESS_API_TOKEN. Добавь его в /etc/llm-harness.env — admin bearer-токен " +
        "(deploy.sh генерирует его при первой установке).",
    );
  }
  const sessionSecret = (env.SESSION_SECRET ?? "").trim();
  if (sessionSecret.length < 16) {
    throw new ConfigError(
      "Не задан SESSION_SECRET (мин. 16 символов). Добавь его в /etc/llm-harness.env — " +
        "секрет для подписи cookie-сессий (deploy.sh генерирует его при первой установке).",
    );
  }
  const port = Number.parseInt(env.HARNESS_PORT ?? "3500", 10);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new ConfigError(`Некорректный HARNESS_PORT: ${env.HARNESS_PORT}`);
  }
  return {
    apiToken,
    sessionSecret,
    adminUser: (env.HARNESS_ADMIN_USER ?? "").trim(),
    host: (env.HARNESS_HOST ?? "127.0.0.1").trim(),
    port,
    dbPath: (env.HARNESS_DB_PATH ?? "/opt/llm-harness/data/harness.db").trim(),
    gwUrl: (env.GW_URL ?? "http://127.0.0.1:3400/gw").trim().replace(/\/$/, ""),
    canary: (env.HARNESS_CANARY ?? "").trim(),
    logLevel: (env.LOG_LEVEL ?? "info").trim(),
  };
}
