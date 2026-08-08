// logger.ts — опции pino для Fastify (с redaction секретов) + тихий логгер
// для тестов (порт из agent-lab).

export interface Logger {
  info(obj: unknown, msg?: string): void;
  warn(obj: unknown, msg?: string): void;
  error(obj: unknown, msg?: string): void;
  debug(obj: unknown, msg?: string): void;
  child?(bindings: Record<string, unknown>): Logger;
}

/** structured JSON в stdout (journald подхватит) + НИКОГДА не пишем секреты. */
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
      ],
      remove: true,
    },
  };
}

export const silentLogger: Logger = {
  info() {},
  warn() {},
  error() {},
  debug() {},
  child() {
    return silentLogger;
  },
};
