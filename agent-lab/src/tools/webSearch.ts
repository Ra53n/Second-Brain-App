// webSearch.ts — веб-поиск через один из внешних провайдеров.
//
// Провайдер и ключ задаются в админке. Без ключа инструмент честно отвечает
// `ERROR: веб-поиск не настроен` — сервис при этом работает, ключ доносится позже.
// Результаты поиска — недоверенные данные: в промпт они попадают уже обёрнутыми
// (см. wrapToolResult), здесь только нормализация ответов трёх разных API.

import type { LabTool } from "./registry.js";
import { stringArg } from "./registry.js";
import type { SearchProvider } from "../domain/types.js";

const TIMEOUT_MS = 12_000;
const MAX_RESULTS = 5;
const MAX_SNIPPET = 400;

export interface SearchHit {
  title: string;
  url: string;
  snippet: string;
}

export interface WebSearchConfig {
  provider: SearchProvider;
  apiKey: string;
}

type Json = Record<string, any>;

function normalize(provider: SearchProvider, data: Json): SearchHit[] {
  const pick = (title: unknown, url: unknown, snippet: unknown): SearchHit => ({
    title: String(title ?? "").slice(0, 200),
    url: String(url ?? ""),
    snippet: String(snippet ?? "").slice(0, MAX_SNIPPET),
  });
  switch (provider) {
    case "tavily":
      return (data.results ?? []).slice(0, MAX_RESULTS).map((r: Json) => pick(r.title, r.url, r.content));
    case "brave":
      return (data.web?.results ?? [])
        .slice(0, MAX_RESULTS)
        .map((r: Json) => pick(r.title, r.url, r.description));
    case "serper":
      return (data.organic ?? []).slice(0, MAX_RESULTS).map((r: Json) => pick(r.title, r.link, r.snippet));
    default:
      return [];
  }
}

function buildRequest(cfg: WebSearchConfig, query: string): { url: string; init: RequestInit } {
  switch (cfg.provider) {
    case "tavily":
      return {
        url: "https://api.tavily.com/search",
        init: {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ api_key: cfg.apiKey, query, max_results: MAX_RESULTS }),
        },
      };
    case "brave":
      return {
        url: `https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=${MAX_RESULTS}`,
        init: { method: "GET", headers: { accept: "application/json", "x-subscription-token": cfg.apiKey } },
      };
    case "serper":
      return {
        url: "https://google.serper.dev/search",
        init: {
          method: "POST",
          headers: { "content-type": "application/json", "x-api-key": cfg.apiKey },
          body: JSON.stringify({ q: query, num: MAX_RESULTS }),
        },
      };
    default:
      throw new Error("провайдер не выбран");
  }
}

export interface WebSearchOptions {
  /** Настройки читаются на каждый вызов: владелец меняет их из админки на лету. */
  config: () => WebSearchConfig;
  fetchImpl?: typeof fetch;
}

export function createWebSearchTool(opts: WebSearchOptions): LabTool {
  const doFetch = opts.fetchImpl ?? fetch;
  return {
    name: "web_search",
    description: "Поиск в интернете. Возвращает заголовки, ссылки и краткие выдержки страниц.",
    parameters: {
      type: "object",
      properties: { query: { type: "string", description: "Поисковый запрос" } },
      required: ["query"],
    },
    async execute(args) {
      const query = stringArg(args, "query");
      if (!query) return "ERROR: не задан параметр query";
      const cfg = opts.config();
      if (cfg.provider === "none" || !cfg.apiKey) {
        return "ERROR: веб-поиск не настроен (владелец не задал провайдера и ключ)";
      }

      const { url, init } = buildRequest(cfg, query);
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
      let resp: Response;
      try {
        resp = await doFetch(url, { ...init, signal: controller.signal });
      } catch (e) {
        return `ERROR: поиск недоступен: ${(e as Error).message}`;
      } finally {
        clearTimeout(timer);
      }
      if (!resp.ok) return `ERROR: поиск ответил ${resp.status}`;

      let data: Json;
      try {
        data = (await resp.json()) as Json;
      } catch {
        return "ERROR: поиск вернул некорректный JSON";
      }
      const hits = normalize(cfg.provider, data);
      if (hits.length === 0) return `По запросу «${query}» ничего не найдено.`;
      return hits.map((h, i) => `${i + 1}. ${h.title}\n${h.url}\n${h.snippet}`).join("\n\n");
    },
  };
}
