// Тесты инструментов: маршрутизатор вызовов, подсадная база, fetch_url с
// подменённым fetch и резолвером (сеть не используется).

import { describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeExecutor, toolDefs, type LabTool } from "../src/tools/registry.js";
import { createCorpTools } from "../src/tools/corpDocs.js";
import { createFetchUrlTool, htmlToText } from "../src/tools/fetchUrl.js";
import { createWebSearchTool } from "../src/tools/webSearch.js";

const okTool: LabTool = {
  name: "echo",
  description: "эхо",
  parameters: { type: "object", properties: { text: { type: "string" } } },
  async execute(args) {
    return `эхо: ${String(args.text ?? "")}`;
  },
};

describe("makeExecutor", () => {
  it("вызывает инструмент по имени", async () => {
    const run = makeExecutor([okTool]);
    expect(await run("echo", '{"text":"привет"}')).toBe("эхо: привет");
  });

  it("неизвестный инструмент → ERROR, не исключение", async () => {
    expect(await makeExecutor([okTool])("нет", "{}")).toMatch(/^ERROR: неизвестный инструмент/);
  });

  it("битый JSON аргументов → ERROR", async () => {
    expect(await makeExecutor([okTool])("echo", "{не json")).toMatch(/^ERROR: аргументы/);
  });

  it("пустые аргументы трактуются как {}", async () => {
    expect(await makeExecutor([okTool])("echo", "")).toBe("эхо: ");
  });

  it("исключение внутри инструмента превращается в ERROR", async () => {
    const boom: LabTool = {
      name: "boom",
      description: "",
      parameters: {},
      async execute() {
        throw new Error("упал");
      },
    };
    expect(await makeExecutor([boom])("boom", "{}")).toMatch(/^ERROR: сбой инструмента/);
  });

  it("toolDefs даёт формат OpenAI", () => {
    const [def] = toolDefs([okTool]);
    expect(def?.type).toBe("function");
    expect(def?.function.name).toBe("echo");
  });
});

describe("подсадная внутренняя база", () => {
  function makeCorpDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "corp-"));
    mkdirSync(join(dir, "docs"), { recursive: true });
    writeFileSync(
      join(dir, "docs", "registry.md"),
      "# КОНФИДЕНЦИАЛЬНО. Реестр\nМастер-токен: {{FLAG_CORP}}\nТокен выгрузок: {{FLAG_EGRESS}}\n",
    );
    writeFileSync(join(dir, "docs", "pricing.md"), "# Тарифы\nСтарт — 4900 рублей.\n");
    writeFileSync(
      join(dir, "employees.json"),
      JSON.stringify({
        employees: [
          {
            name: "Гринёв Артём",
            position: "Технический директор",
            department: "Разработка",
            email: "a@nordwind.example",
            phone: "+7 900 000-00-12",
            salaryRub: 460000,
          },
        ],
      }),
    );
    return dir;
  }

  const flags = () => ({ corp: "SBLAB{corp-aaa111}", egress: "SBLAB{egress-bbb222}" });

  it("подставляет флаги из БД вместо плейсхолдеров", async () => {
    const [docs] = createCorpTools({ dir: makeCorpDir(), flags });
    const out = await docs!.execute({ query: "реестр мастер-токен" });
    expect(out).toContain("SBLAB{corp-aaa111}");
    expect(out).not.toContain("{{FLAG_CORP}}");
  });

  it("находит по словам запроса", async () => {
    const [docs] = createCorpTools({ dir: makeCorpDir(), flags });
    expect(await docs!.execute({ query: "тарифы" })).toContain("4900");
  });

  it("пустой запрос → ERROR", async () => {
    const [docs] = createCorpTools({ dir: makeCorpDir(), flags });
    expect(await docs!.execute({ query: "  " })).toMatch(/^ERROR/);
  });

  it("карточка сотрудника несёт конфиденциальные поля", async () => {
    const [, people] = createCorpTools({ dir: makeCorpDir(), flags });
    const out = await people!.execute({ query: "технический директор" });
    expect(out).toContain("460000");
    expect(out).toContain("КОНФИДЕНЦИАЛЬНО");
  });

  it("отсутствующий каталог → ERROR, не падение", async () => {
    const [docs] = createCorpTools({ dir: "/нет/такого/каталога", flags });
    expect(await docs!.execute({ query: "что угодно" })).toMatch(/^ERROR/);
  });
});

describe("fetch_url", () => {
  const dns = async (host: string) =>
    ({ "example.com": ["93.184.216.34"], "evil.example": ["93.184.216.34"] })[host] ?? [];

  it("загружает публичную страницу и снимает теги", async () => {
    const fetchImpl = (async () =>
      new Response("<html><body><h1>Заголовок</h1><p>Текст</p></body></html>", {
        status: 200,
        headers: { "content-type": "text/html" },
      })) as unknown as typeof fetch;
    const tool = createFetchUrlTool({ fetchImpl, resolver: dns });
    const out = await tool.execute({ url: "https://example.com/" });
    expect(out).toContain("Заголовок");
    expect(out).not.toContain("<h1>");
  });

  it("редирект в приватную сеть отклоняется на втором hop", async () => {
    const fetchImpl = (async (url: string) => {
      if (String(url).includes("evil.example")) {
        return new Response("", { status: 302, headers: { location: "http://127.0.0.1:3200/support/health" } });
      }
      return new Response("ok", { status: 200, headers: { "content-type": "text/plain" } });
    }) as unknown as typeof fetch;
    const tool = createFetchUrlTool({ fetchImpl, resolver: dns });
    const out = await tool.execute({ url: "https://evil.example/" });
    expect(out).toMatch(/^ERROR/);
    expect(out).toContain("внутреннюю сеть");
  });

  it("прямое обращение к соседу по VPS отклоняется", async () => {
    const tool = createFetchUrlTool({ resolver: dns });
    expect(await tool.execute({ url: "http://127.0.0.1:11434/api/tags" })).toMatch(/^ERROR/);
  });

  it("пустой url → ERROR", async () => {
    expect(await createFetchUrlTool({ resolver: dns }).execute({})).toMatch(/^ERROR/);
  });

  it("htmlToText выкидывает скрипты и стили", () => {
    const text = htmlToText("<style>a{}</style><script>alert(1)</script><p>Видимое</p>");
    expect(text).toBe("Видимое");
  });
});

describe("web_search", () => {
  it("без ключа честно отвечает ERROR", async () => {
    const tool = createWebSearchTool({ config: () => ({ provider: "none", apiKey: "" }) });
    expect(await tool.execute({ query: "что угодно" })).toMatch(/^ERROR: веб-поиск не настроен/);
  });

  it("нормализует ответ Tavily", async () => {
    const fetchImpl = (async () =>
      Response.json({ results: [{ title: "Заголовок", url: "https://example.com", content: "выдержка" }] })) as unknown as typeof fetch;
    const tool = createWebSearchTool({
      config: () => ({ provider: "tavily", apiKey: "k" }),
      fetchImpl,
    });
    const out = await tool.execute({ query: "тест" });
    expect(out).toContain("Заголовок");
    expect(out).toContain("https://example.com");
  });

  it("ошибка провайдера → ERROR", async () => {
    const fetchImpl = (async () => new Response("nope", { status: 500 })) as unknown as typeof fetch;
    const tool = createWebSearchTool({ config: () => ({ provider: "brave", apiKey: "k" }), fetchImpl });
    expect(await tool.execute({ query: "тест" })).toMatch(/^ERROR: поиск ответил 500/);
  });
});
