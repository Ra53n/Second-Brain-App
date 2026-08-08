// fetchUrl.ts — загрузка страницы по ссылке.
//
// Главный вектор косвенной инъекции лаборатории: атакующий хостит свою страницу
// с закладкой и просит агента её прочитать. И одновременно главный риск сервиса:
// без SSRF-гарда это чтение соседних сервисов VPS. Поэтому каждый hop редиректа
// проходит assertPublicUrl заново — публичный домен вправе редиректнуть на 127.0.0.1.

import type { LabTool } from "./registry.js";
import { stringArg } from "./registry.js";
import { assertPublicUrl, UrlPolicyError, type Resolver } from "../guard/urlPolicy.js";

const TIMEOUT_MS = 10_000;
const MAX_BYTES = 256 * 1024;
const MAX_REDIRECTS = 3;
const MAX_TEXT_CHARS = 8000;
const USER_AGENT = "agent-lab/0.1 (+security lab)";

/** HTML → читаемый текст: скрипты и стили выкидываем целиком, теги снимаем. */
export function htmlToText(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|h[1-6]|tr)>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** Читает тело с жёстким потолком: страница на 50 МБ не должна убить процесс. */
async function readCapped(resp: Response): Promise<string> {
  const reader = resp.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (total < MAX_BYTES) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value) {
      chunks.push(value);
      total += value.byteLength;
    }
  }
  await reader.cancel().catch(() => undefined);
  return Buffer.concat(chunks.map((c) => Buffer.from(c))).subarray(0, MAX_BYTES).toString("utf8");
}

export interface FetchUrlOptions {
  fetchImpl?: typeof fetch;
  resolver?: Resolver;
}

export function createFetchUrlTool(opts: FetchUrlOptions = {}): LabTool {
  const doFetch = opts.fetchImpl ?? fetch;
  return {
    name: "fetch_url",
    description:
      "Загрузить страницу по ссылке и вернуть её текст. Ссылку берёшь только ту, что дал собеседник.",
    parameters: {
      type: "object",
      properties: { url: { type: "string", description: "Полный адрес страницы (http/https)" } },
      required: ["url"],
    },
    async execute(args) {
      const raw = stringArg(args, "url");
      if (!raw) return "ERROR: не задан параметр url";

      let target = raw;
      for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
        let checked;
        try {
          checked = await assertPublicUrl(target, opts.resolver);
        } catch (e) {
          if (e instanceof UrlPolicyError) return `ERROR: ${e.message}`;
          return `ERROR: не удалось проверить адрес: ${(e as Error).message}`;
        }

        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
        let resp: Response;
        try {
          resp = await doFetch(checked.url.toString(), {
            method: "GET",
            redirect: "manual",
            signal: controller.signal,
            headers: { "user-agent": USER_AGENT, accept: "text/html,text/plain,*/*;q=0.8" },
          });
        } catch (e) {
          return `ERROR: не удалось загрузить страницу: ${(e as Error).message}`;
        } finally {
          clearTimeout(timer);
        }

        if (resp.status >= 300 && resp.status < 400) {
          const location = resp.headers.get("location");
          if (!location) return `ERROR: редирект без адреса (${resp.status})`;
          target = new URL(location, checked.url).toString();
          continue;
        }
        if (!resp.ok) return `ERROR: страница ответила ${resp.status}`;

        const contentType = resp.headers.get("content-type") ?? "";
        const body = await readCapped(resp);
        const text = contentType.includes("html") ? htmlToText(body) : body.trim();
        if (!text) return "Страница загрузилась, но текста в ней нет.";
        return `Страница ${checked.url.toString()}:\n\n${text.slice(0, MAX_TEXT_CHARS)}`;
      }
      return `ERROR: слишком много редиректов (больше ${MAX_REDIRECTS})`;
    },
  };
}
