// gwClient.ts — ЕДИНСТВЕННАЯ точка выхода harness наружу: POST $GW_URL/chat.
// И генерация, и security review идут только сюда. Прямых обращений к DeepSeek
// в harness нет — ключ живёт в gateway. Ретраи 429 (Retry-After) и 5xx.

import { UpstreamError } from "../domain/errors.js";

export interface GatewayMeta {
  inputAction?: string;
  outputVerdict?: string;
  outputIssues?: unknown[];
  findings?: Array<{ type?: string; kind?: string; encoding?: string }>;
  model?: string;
  usage?: { promptTokens?: number; completionTokens?: number; totalTokens?: number };
  costUsd?: number;
}

export interface GatewayReply {
  answer: string;
  blocked: boolean;
  warning: string | null;
  meta: GatewayMeta;
}

const HTTP_TIMEOUT_MS = 180_000;
const MAX_RETRIES = 5;

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

export class GatewayClient {
  constructor(
    private readonly baseUrl: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async chat(prompt: string): Promise<GatewayReply> {
    let lastErr = "нет ответа";
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), HTTP_TIMEOUT_MS);
      try {
        const resp = await this.fetchImpl(`${this.baseUrl}/chat`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ prompt }),
          signal: ctl.signal,
        });
        if (resp.status === 429) {
          const ra = Number.parseInt(resp.headers.get("retry-after") ?? "", 10);
          await sleep(Number.isFinite(ra) && ra > 0 ? ra * 1000 : 20_000);
          lastErr = "429 rate limit";
          continue;
        }
        if (resp.status >= 500) {
          lastErr = `HTTP ${resp.status}`;
          await sleep(5000 * (attempt + 1));
          continue;
        }
        if (!resp.ok) {
          const text = await resp.text().catch(() => "");
          throw new UpstreamError(`gateway ответил ${resp.status}: ${text.slice(0, 200)}`);
        }
        const data = (await resp.json()) as {
          answer?: string;
          blocked?: boolean;
          warning?: string | null;
          meta?: GatewayMeta;
        };
        return {
          answer: data.answer ?? "",
          blocked: Boolean(data.blocked),
          warning: data.warning ?? null,
          meta: data.meta ?? {},
        };
      } catch (err) {
        if (err instanceof UpstreamError) throw err;
        lastErr = (err as Error).message;
        await sleep(5000 * (attempt + 1));
      } finally {
        clearTimeout(timer);
      }
    }
    throw new UpstreamError(`gateway недоступен после ${MAX_RETRIES} попыток: ${lastErr}`);
  }
}
