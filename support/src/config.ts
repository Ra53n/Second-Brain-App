// config.ts — чтение и валидация bootstrap-конфигурации из окружения.
//
// ВАЖНО (по дизайну, как у manager-agent): в /etc/support-assistant.env лежит
// ТОЛЬКО bootstrap:
//   SUPPORT_API_TOKEN — admin bearer-токен (скрипты/curl, обход веб-сессий);
//   SESSION_SECRET — секрет подписи cookie веб-сессий (генерится deploy.sh);
//   SUPPORT_HOST / SUPPORT_PORT — где слушает HTTP (127.0.0.1:3200);
//   SUPPORT_DB_PATH — путь к SQLite;
//   SUPPORT_KB_DIR / SUPPORT_CRM_DIR — каталоги базы знаний и CRM-JSON;
//   OLLAMA_URL — локальная Ollama (loopback);
//   LOG_LEVEL — уровень логов.
// LLM-провайдер/ключ/модели задаются из админки и лежат в SQLite (settings).

export interface BootstrapConfig {
  apiToken: string;
  sessionSecret: string;
  host: string;
  port: number;
  dbPath: string;
  kbDir: string;
  crmDir: string;
  logLevel: string;
  ollamaUrl: string;
}

/** Ошибка отсутствия обязательной bootstrap-переменной (видна в journalctl). */
export class ConfigError extends Error {}

/**
 * Считывает конфигурацию из переданного окружения (по умолчанию process.env).
 * Падает с понятным сообщением, если нет обязательной переменной.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): BootstrapConfig {
  const apiToken = (env.SUPPORT_API_TOKEN ?? "").trim();
  if (!apiToken) {
    throw new ConfigError(
      "Не задан SUPPORT_API_TOKEN. Добавь его в /etc/support-assistant.env — это admin " +
        "bearer-токен сервиса (deploy.sh генерирует его при первой установке).",
    );
  }

  const sessionSecret = (env.SESSION_SECRET ?? "").trim();
  if (!sessionSecret) {
    throw new ConfigError(
      "Не задан SESSION_SECRET. Добавь его в /etc/support-assistant.env — это секрет " +
        "подписи cookie веб-сессий (deploy.sh генерирует его автоматически).",
    );
  }

  const port = parseInt(env.SUPPORT_PORT ?? "3200", 10);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new ConfigError(`Некорректный SUPPORT_PORT: ${env.SUPPORT_PORT}`);
  }

  return {
    apiToken,
    sessionSecret,
    host: (env.SUPPORT_HOST ?? "127.0.0.1").trim(),
    port,
    dbPath: (env.SUPPORT_DB_PATH ?? "/opt/support-assistant/data/support.db").trim(),
    kbDir: (env.SUPPORT_KB_DIR ?? "/opt/support-assistant/data/kb").trim(),
    crmDir: (env.SUPPORT_CRM_DIR ?? "/opt/support-assistant/data/crm").trim(),
    logLevel: (env.LOG_LEVEL ?? "info").trim(),
    ollamaUrl: (env.OLLAMA_URL ?? "http://127.0.0.1:11434").trim(),
  };
}
