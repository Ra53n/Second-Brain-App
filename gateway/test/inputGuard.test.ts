// inputGuard.test.ts — ключевые тест-кейсы домашки «День 13» (input guard).
// Значения секретов заведомо фейковые (не совпадают с реальными ключами), но
// синтаксически валидные для своих префиксов.

import { describe, it, expect } from "vitest";
import {
  detectSecrets,
  maskSecrets,
  applyInputPolicy,
  luhnValid,
  type SecretType,
} from "../src/guard/inputGuard.js";

function kinds(text: string): string[] {
  return detectSecrets(text).map((f) => f.kind);
}
function types(text: string): SecretType[] {
  return detectSecrets(text).map((f) => f.type);
}

describe("детекция секретов (10 кейсов домашки)", () => {
  it("1. AWS access key (AKIA)", () => {
    expect(kinds("ключ доступа AKIAIOSFODNN7EXAMPLE от бакета")).toContain("aws_access_key");
  });

  it("2. номер карты с валидным Luhn ловится, а невалидный — нет", () => {
    expect(luhnValid("4242424242424242")).toBe(true);
    expect(types("оплата картой 4242 4242 4242 4242")).toContain("credit_card");
    // Контроль ложных срабатываний: те же 16 цифр, но Luhn не сходится.
    expect(types("номер заказа 4242 4242 4242 4241")).not.toContain("credit_card");
  });

  it("3. Base64-encoded секрет декодируется и ловится", () => {
    const secret = "AKIAIOSFODNN7EXAMPLE";
    const b64 = Buffer.from(secret, "utf8").toString("base64");
    const findings = detectSecrets(`вот в base64: ${b64}`);
    expect(findings.some((f) => f.encoding === "base64" && f.kind === "aws_access_key")).toBe(true);
  });

  it("4. секрет, разбитый на части (конкатенация литералов)", () => {
    const findings = detectSecrets('key = "sk-" + "proj-abc123def456"');
    expect(findings.some((f) => f.encoding === "joined" && f.type === "api_key")).toBe(true);
  });

  it("5. чистый промпт без секретов — ноль находок", () => {
    expect(detectSecrets("Помоги переписать абзац про кэширование в README.")).toEqual([]);
  });

  it("6. email", () => {
    expect(types("пиши на ivan.petrov@example.com")).toContain("email");
  });

  it("7. телефон", () => {
    expect(types("звони +7 900 123-45-67 после обеда")).toContain("phone");
    // Голый длинный ряд цифр телефоном не считается.
    expect(types("id записи 79001234567")).not.toContain("phone");
  });

  it("8. GitHub token (ghp_)", () => {
    expect(kinds("токен ghp_0123456789abcdefghijABCDEFGHIJ0123 в конфиге")).toContain("github_token");
  });

  it("9. Google API key (AIza)", () => {
    expect(kinds("AIzaSyA1234567890abcdefghijklmnopqrstuvw в url")).toContain("google_key");
  });

  it("10. OpenAI/DeepSeek key (sk-)", () => {
    expect(kinds("мой ключ sk-abcDEF1234567890ghiJKL тут")).toContain("openai_key");
  });
});

describe("маскирование", () => {
  it("sk-proj-abc123 → [REDACTED_API_KEY], остальной текст цел", () => {
    const { masked } = maskSecrets("возьми sk-proj-abc123def456ghi789 и вставь");
    expect(masked).toBe("возьми [REDACTED_API_KEY] и вставь");
  });

  it("разные типы — свои плейсхолдеры", () => {
    const { masked } = maskSecrets("почта a@b.com карта 4242 4242 4242 4242 тел +7 900 123 45 67");
    expect(masked).toContain("[REDACTED_EMAIL]");
    expect(masked).toContain("[REDACTED_CARD]");
    expect(masked).toContain("[REDACTED_PHONE]");
  });
});

describe("политика input guard", () => {
  it("block — секрет найден, запрос блокируется целиком", () => {
    const d = applyInputPolicy("ключ AKIAIOSFODNN7EXAMPLE", { default: "block" });
    expect(d.action).toBe("block");
    if (d.action === "block") expect(d.warning).toMatch(/заблокирован/i);
  });

  it("mask — секрет маскируется, запрос пропускается", () => {
    const d = applyInputPolicy("ключ sk-abcDEF1234567890ghiJKL", { default: "mask" });
    expect(d.action).toBe("mask");
    if (d.action === "mask") expect(d.text).toContain("[REDACTED_API_KEY]");
  });

  it("allow — чистый промпт проходит без изменений", () => {
    const d = applyInputPolicy("обычный вопрос про SwiftUI", { default: "block" });
    expect(d.action).toBe("allow");
    if (d.action === "allow") expect(d.text).toBe("обычный вопрос про SwiftUI");
  });

  it("byType переопределяет режим на конкретный тип", () => {
    // Дефолт mask, но карты — block. Есть карта → блок всего запроса.
    const d = applyInputPolicy("карта 4242 4242 4242 4242", {
      default: "mask",
      byType: { credit_card: "block" },
    });
    expect(d.action).toBe("block");
  });
});
