// Тесты структурного чанкера markdown (кейсы портированы из Swift-тестов).

import { describe, expect, it } from "vitest";
import { chunkMarkdown, headingTitle } from "../src/rag/chunker.js";

describe("headingTitle", () => {
  it("распознаёт ATX-заголовки с уровнем", () => {
    expect(headingTitle("# Один")).toEqual({ level: 1, title: "Один" });
    expect(headingTitle("### Три ")).toEqual({ level: 3, title: "Три" });
  });

  it("требует пробел после решёток (CommonMark)", () => {
    expect(headingTitle("#Без пробела")).toBeNull();
    expect(headingTitle("####### Семь")).toBeNull();
    expect(headingTitle("обычная строка")).toBeNull();
  });
});

describe("chunkMarkdown", () => {
  it("пустой текст → пустой массив", () => {
    expect(chunkMarkdown("", "f.md")).toEqual([]);
    expect(chunkMarkdown("  \n \n", "f.md")).toEqual([]);
  });

  it("режет по заголовкам и строит заголовочный путь", () => {
    const text = "# Гид\nвступление\n## Установка\nшаги\n## Настройка\nдетали";
    const chunks = chunkMarkdown(text, "guide.md");
    expect(chunks.map((c) => c.headingPath)).toEqual([
      "Гид",
      "Гид > Установка",
      "Гид > Настройка",
    ]);
    expect(chunks[1]!.text).toContain("шаги");
    expect(chunks.every((c) => c.filePath === "guide.md")).toBe(true);
  });

  it("преамбула до заголовков — пустой headingPath", () => {
    const chunks = chunkMarkdown("просто текст\n# Заголовок\nтело", "f.md");
    expect(chunks[0]!.headingPath).toBe("");
    expect(chunks[1]!.headingPath).toBe("Заголовок");
  });

  it("заголовки внутри код-блоков не считаются заголовками", () => {
    const text = "# Раздел\n```\n# не заголовок\n```\nконец";
    const chunks = chunkMarkdown(text, "f.md");
    expect(chunks).toHaveLength(1);
    expect(chunks[0]!.text).toContain("# не заголовок");
  });

  it("длинные разделы дорезаются с сохранением пути", () => {
    const long = Array.from({ length: 50 }, (_, i) => `строка номер ${i} с текстом`).join("\n");
    const chunks = chunkMarkdown(`# Большой\n${long}`, "f.md", 200);
    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.every((c) => c.headingPath === "Большой")).toBe(true);
    expect(chunks.every((c) => c.text.length <= 200 + 40)).toBe(true);
  });

  it("сброс стека заголовков на том же уровне", () => {
    const text = "# A\n## B\nx\n# C\ny";
    const chunks = chunkMarkdown(text, "f.md");
    expect(chunks.map((c) => c.headingPath)).toEqual(["A", "A > B", "C"]);
  });
});
