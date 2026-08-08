// Тесты SSRF-гарда. Резолвер инжектируется — сеть в тестах не используется.

import { describe, expect, it } from "vitest";
import { assertPublicUrl, isBlockedAddress, UrlPolicyError } from "../src/guard/urlPolicy.js";

/** Резолвер-заглушка: хост → адреса. Неизвестный хост «падает», как настоящий DNS. */
const resolver = (map: Record<string, string[]>) => async (host: string) => {
  const found = map[host];
  if (!found) throw new Error("NXDOMAIN");
  return found;
};

describe("isBlockedAddress", () => {
  const blocked = [
    "127.0.0.1",
    "127.1.2.3",
    "0.0.0.0",
    "10.0.0.5",
    "172.16.0.1",
    "172.31.255.255",
    "192.168.1.1",
    "169.254.169.254",
    "100.64.0.1",
    "224.0.0.1",
    "255.255.255.255",
    "::1",
    "::",
    "fd00::1",
    "fe80::1",
    "::ffff:127.0.0.1",
  ];
  for (const ip of blocked) it(`блокирует ${ip}`, () => expect(isBlockedAddress(ip)).toBe(true));

  const allowed = ["8.8.8.8", "1.1.1.1", "93.184.216.34", "78.17.96.131", "2606:4700::1111"];
  for (const ip of allowed) it(`пропускает ${ip}`, () => expect(isBlockedAddress(ip)).toBe(false));

  it("неразбираемый адрес считается опасным", () => {
    expect(isBlockedAddress("не адрес")).toBe(true);
    expect(isBlockedAddress("999.1.1.1")).toBe(true);
  });
});

describe("assertPublicUrl", () => {
  const dns = resolver({
    "example.com": ["93.184.216.34"],
    "evil.example": ["127.0.0.1"],
    "mixed.example": ["8.8.8.8", "10.0.0.7"],
  });

  it("пропускает публичный домен", async () => {
    const checked = await assertPublicUrl("https://example.com/page", dns);
    expect(checked.url.hostname).toBe("example.com");
  });

  const rejects: Array<[string, string]> = [
    ["http://127.0.0.1:3200/support/health", "литеральный loopback"],
    ["http://localhost:3300/lab/admin", "localhost через DNS"],
    ["http://10.0.0.5/", "приватная сеть"],
    ["http://169.254.169.254/latest/meta-data/", "метаданные облака"],
    ["http://[::1]:11434/api/tags", "IPv6 loopback"],
    ["https://evil.example/", "публичный домен с приватным A-record"],
    ["https://mixed.example/", "один из адресов приватный"],
    ["file:///etc/agent-lab.env", "схема file"],
    ["gopher://example.com/", "схема gopher"],
    ["https://user:pass@example.com/", "логин и пароль в адресе"],
    ["не адрес вовсе", "мусор вместо URL"],
  ];

  for (const [url, why] of rejects) {
    it(`отклоняет ${why}`, async () => {
      const localDns = resolver({
        "example.com": ["93.184.216.34"],
        "evil.example": ["127.0.0.1"],
        "mixed.example": ["8.8.8.8", "10.0.0.7"],
        localhost: ["127.0.0.1"],
      });
      await expect(assertPublicUrl(url, localDns)).rejects.toBeInstanceOf(UrlPolicyError);
    });
  }

  it("хост, который никуда не резолвится, отклоняется", async () => {
    await expect(assertPublicUrl("https://nowhere.invalid/", dns)).rejects.toBeInstanceOf(UrlPolicyError);
  });
});
