// tavily.ts — клиент Tavily (веб-поиск + извлечение контента ссылок).
// Tavily сам ходит по URL на своей стороне, поэтому SSRF на нашем сервере нет.
// Ключ приходит из env (TAVILY_API_KEY), в git не хранится.

export interface SearchHit {
  title: string;
  url: string;
  content: string;
}

export interface ExtractHit {
  url: string;
  content: string;
}

const API = "https://api.tavily.com";
const TIMEOUT_MS = 20_000;
const MAX_CONTENT = 4000; // на источник — режем, чтобы не раздувать промпт

function clip(s: string): string {
  const t = (s ?? "").trim();
  return t.length <= MAX_CONTENT ? t : t.slice(0, MAX_CONTENT) + "…";
}

export class TavilyClient {
  constructor(
    private readonly apiKey: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  get enabled(): boolean {
    return this.apiKey.length > 0;
  }

  private async post(path: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
    try {
      const resp = await this.fetchImpl(`${API}${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ api_key: this.apiKey, ...body }),
        signal: ctl.signal,
      });
      if (!resp.ok) throw new Error(`Tavily ${path} ответил ${resp.status}`);
      return (await resp.json()) as Record<string, unknown>;
    } finally {
      clearTimeout(timer);
    }
  }

  /** Веб-поиск: до maxResults результатов с кратким контентом. */
  async search(query: string, maxResults = 5): Promise<SearchHit[]> {
    if (!this.enabled) return [];
    const data = await this.post("/search", {
      query: query.slice(0, 400),
      max_results: maxResults,
      search_depth: "basic",
    });
    const results = Array.isArray(data.results) ? (data.results as Array<Record<string, unknown>>) : [];
    return results.map((r) => ({
      title: String(r.title ?? ""),
      url: String(r.url ?? ""),
      content: clip(String(r.content ?? "")),
    }));
  }

  /** Извлечение текста по конкретным URL (Tavily фетчит сам). */
  async extract(urls: string[]): Promise<ExtractHit[]> {
    if (!this.enabled || urls.length === 0) return [];
    const data = await this.post("/extract", { urls: urls.slice(0, 5) });
    const results = Array.isArray(data.results) ? (data.results as Array<Record<string, unknown>>) : [];
    return results.map((r) => ({ url: String(r.url ?? ""), content: clip(String(r.raw_content ?? r.content ?? "")) }));
  }
}
