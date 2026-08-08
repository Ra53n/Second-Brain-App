// config.ts — чтение и валидация bootstrap-конфигурации из окружения.
//
// В /etc/agent-lab.env лежит ТОЛЬКО bootstrap (как у support-assistant):
//   LAB_API_TOKEN   — admin bearer-токен (админка, curl, атака-смоук);
//   SESSION_SECRET  — секрет подписи cookie сессий (генерится deploy.sh);
//   LAB_HOST/PORT   — где слушает HTTP (127.0.0.1:3300);
//   LAB_DB_PATH     — путь к SQLite;
//   LAB_CORP_DIR    — каталог подсадной «внутренней базы»;
//   LAB_ACCESS_CODE — первоначальный код доступа для атакующих (хешируется
//                     при старте и дальше меняется из админки);
//   LOG_LEVEL       — уровень логов.
// Ключ LLM, ключ поиска и уровень защиты задаются из админки и лежат в SQLite.

export interface BootstrapConfig {
  apiToken: string;
  sessionSecret: string;
  host: string;
  port: number;
  dbPath: string;
  corpDir: string;
  accessCode: string;
  logLevel: string;
}

/** Ошибка отсутствия обязательной bootstrap-переменной (видна в journalctl). */
export class ConfigError extends Error {}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): BootstrapConfig {
  const apiToken = (env.LAB_API_TOKEN ?? "").trim();
  if (!apiToken) {
    throw new ConfigError(
      "Не задан LAB_API_TOKEN. Добавь его в /etc/agent-lab.env — это admin bearer-токен " +
        "сервиса (deploy.sh генерирует его при первой установке).",
    );
  }
  const sessionSecret = (env.SESSION_SECRET ?? "").trim();
  if (!sessionSecret) {
    throw new ConfigError(
      "Не задан SESSION_SECRET. Добавь его в /etc/agent-lab.env — это секрет подписи " +
        "cookie сессий (deploy.sh генерирует его автоматически).",
    );
  }
  const port = Number.parseInt(env.LAB_PORT ?? "3300", 10);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new ConfigError(`Некорректный LAB_PORT: ${env.LAB_PORT}`);
  }

  return {
    apiToken,
    sessionSecret,
    host: (env.LAB_HOST ?? "127.0.0.1").trim(),
    port,
    dbPath: (env.LAB_DB_PATH ?? "/opt/agent-lab/data/lab.db").trim(),
    corpDir: (env.LAB_CORP_DIR ?? "/opt/agent-lab/data/corp").trim(),
    accessCode: (env.LAB_ACCESS_CODE ?? "").trim(),
    logLevel: (env.LOG_LEVEL ?? "info").trim(),
  };
}
