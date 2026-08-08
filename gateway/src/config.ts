// config.ts — bootstrap-конфигурация из окружения.
//
// В /etc/llm-gateway.env лежит ТОЛЬКО bootstrap:
//   GW_API_TOKEN  — admin bearer-токен (админка, curl);
//   SESSION_SECRET — секрет для будущих подписей (резерв, генерится deploy.sh);
//   GW_HOST/PORT  — где слушает HTTP (127.0.0.1:3400);
//   GW_DB_PATH    — путь к SQLite;
//   LOG_LEVEL     — уровень логов.
// Ключ LLM, тарифы, персона и политика гарда задаются из админки и лежат в SQLite.

import { ConfigError } from "./domain/errors.js";

export interface BootstrapConfig {
  apiToken: string;
  sessionSecret: string;
  host: string;
  port: number;
  dbPath: string;
  logLevel: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): BootstrapConfig {
  const apiToken = (env.GW_API_TOKEN ?? "").trim();
  if (!apiToken) {
    throw new ConfigError(
      "Не задан GW_API_TOKEN. Добавь его в /etc/llm-gateway.env — это admin bearer-токен " +
        "сервиса (deploy.sh генерирует его при первой установке).",
    );
  }
  const port = Number.parseInt(env.GW_PORT ?? "3400", 10);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new ConfigError(`Некорректный GW_PORT: ${env.GW_PORT}`);
  }
  return {
    apiToken,
    sessionSecret: (env.SESSION_SECRET ?? "").trim(),
    host: (env.GW_HOST ?? "127.0.0.1").trim(),
    port,
    dbPath: (env.GW_DB_PATH ?? "/opt/llm-gateway/data/gateway.db").trim(),
    logLevel: (env.LOG_LEVEL ?? "info").trim(),
  };
}
