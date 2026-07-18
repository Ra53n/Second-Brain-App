// logger.ts — логирование (порт из manager-agent). Используем встроенный в
// Fastify pino: здесь только опции (с redaction секретов) + совместимый
// интерфейс Logger для сервисов вне HTTP-контекста и «тихий» логгер для тестов.

/** Минимальный структурный интерфейс логгера (его удовлетворяет pino из Fastify). */
export interface Logger {
  info(obj: unknown, msg?: string): void;
  warn(obj: unknown, msg?: string): void;
  error(obj: unknown, msg?: string): void;
  debug(obj: unknown, msg?: string): void;
  child?(bindings: Record<string, unknown>): Logger;
}

/**
 * Опции логгера Fastify: structured JSON в stdout (journald подхватит) +
 * redaction — НИКОГДА не пишем Authorization и значения секретов в логи.
 */
export function fastifyLoggerOptions(level: string) {
  return {
    level,
    redact: {
      paths: [
        "req.headers.authorization",
        "headers.authorization",
        "*.llmApiKey",
        "*.apiToken",
        "*.env",
        "*.args",
      ],
      remove: true,
    },
  };
}

/** Тихий логгер для тестов и фолбэков. */
export const silentLogger: Logger = {
  info() {},
  warn() {},
  error() {},
  debug() {},
  child() {
    return silentLogger;
  },
};
