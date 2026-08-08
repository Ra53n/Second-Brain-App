// logger.ts — pino с редакцией секретов. Порт gateway/src/logger.ts.

import type { FastifyServerOptions } from "fastify";

export function fastifyLoggerOptions(level: string): FastifyServerOptions["logger"] {
  return {
    level,
    redact: {
      paths: ["req.headers.authorization", "*.apiToken", "*.canary", "*.env"],
      remove: true,
    },
  };
}
