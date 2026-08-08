// urlPolicy.ts — SSRF-гард для fetch_url.
//
// Сервис живёт на VPS рядом с чужими сервисами (manager-agent :3100,
// support-assistant :3200, Ollama :11434, yougile-mcp :3000) и их SQLite-базами.
// Без этой проверки «прочитай страницу» превращается в чтение данных соседей,
// а 169.254.169.254 — в метаданные облака. Проверяется КАЖДЫЙ адрес, полученный
// из DNS, и КАЖДЫЙ hop редиректа: публичный домен вправе редиректнуть на 127.0.0.1.

import { lookup } from "node:dns/promises";

/** Резолвер адресов (инжектируется в тестах). */
export type Resolver = (host: string) => Promise<string[]>;

export const dnsResolver: Resolver = async (host) => {
  const records = await lookup(host, { all: true, verbatim: true });
  return records.map((r) => r.address);
};

const ALLOWED_PROTOCOLS = new Set(["http:", "https:"]);

function ipv4ToInt(ip: string): number | null {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  let value = 0;
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const n = Number(part);
    if (n > 255) return null;
    value = value * 256 + n;
  }
  return value;
}

/** CIDR-блоки, запрещённые к обращению. */
const BLOCKED_V4: Array<[string, number]> = [
  ["0.0.0.0", 8], // «этот» хост
  ["10.0.0.0", 8], // приватная сеть
  ["100.64.0.0", 10], // CGNAT
  ["127.0.0.0", 8], // loopback — соседние сервисы VPS
  ["169.254.0.0", 16], // link-local, метаданные облака
  ["172.16.0.0", 12], // приватная сеть, docker-мосты
  ["192.0.0.0", 24], // IETF protocol assignments
  ["192.168.0.0", 16], // приватная сеть
  ["198.18.0.0", 15], // benchmarking
  ["224.0.0.0", 4], // multicast
  ["240.0.0.0", 4], // reserved + broadcast
];

function isBlockedV4(ip: string): boolean {
  const value = ipv4ToInt(ip);
  if (value === null) return true; // не разобрали — считаем опасным
  for (const [base, bits] of BLOCKED_V4) {
    const baseValue = ipv4ToInt(base);
    if (baseValue === null) continue;
    const mask = bits === 0 ? 0 : (-1 << (32 - bits)) >>> 0;
    if ((value & mask) >>> 0 === (baseValue & mask) >>> 0) return true;
  }
  return false;
}

function isBlockedV6(ip: string): boolean {
  const addr = ip.toLowerCase().split("%")[0] ?? "";
  // IPv4-mapped / IPv4-compatible: проверяем встроенный v4-адрес.
  const mapped = addr.match(/^::(?:ffff:)?(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (mapped?.[1]) return isBlockedV4(mapped[1]);
  if (addr === "::" || addr === "::1") return true;
  if (/^f[cd][0-9a-f]{2}:/.test(addr)) return true; // fc00::/7 — unique local
  if (/^fe[89ab][0-9a-f]:/.test(addr)) return true; // fe80::/10 — link-local
  if (/^ff[0-9a-f]{2}:/.test(addr)) return true; // ff00::/8 — multicast
  return false;
}

export function isBlockedAddress(ip: string): boolean {
  return ip.includes(":") ? isBlockedV6(ip) : isBlockedV4(ip);
}

export class UrlPolicyError extends Error {}

export interface CheckedUrl {
  url: URL;
  /** Адреса, в которые резолвится хост — по ним и пойдёт запрос. */
  addresses: string[];
}

/**
 * Проверяет URL перед сетевым обращением. Бросает `UrlPolicyError` с текстом,
 * пригодным для показа модели (инструмент вернёт его как `ERROR: …`).
 */
export async function assertPublicUrl(raw: string, resolve: Resolver = dnsResolver): Promise<CheckedUrl> {
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    throw new UrlPolicyError(`не похоже на адрес: ${raw.slice(0, 120)}`);
  }
  if (!ALLOWED_PROTOCOLS.has(url.protocol)) {
    throw new UrlPolicyError(`схема ${url.protocol} запрещена, разрешены только http и https`);
  }
  if (url.username || url.password) {
    throw new UrlPolicyError("адреса с логином и паролем запрещены");
  }

  const host = url.hostname.replace(/^\[|\]$/g, "");
  // Литеральный IP в адресе не резолвим — проверяем напрямую.
  const literal = /^[\d.]+$/.test(host) || host.includes(":");
  let addresses: string[];
  if (literal) {
    addresses = [host];
  } else {
    try {
      addresses = await resolve(host);
    } catch {
      throw new UrlPolicyError(`не удалось определить адрес хоста ${host}`);
    }
    if (addresses.length === 0) throw new UrlPolicyError(`хост ${host} никуда не резолвится`);
  }

  for (const address of addresses) {
    if (isBlockedAddress(address)) {
      throw new UrlPolicyError(
        `адрес ${host} ведёт во внутреннюю сеть (${address}) — обращение запрещено`,
      );
    }
  }
  return { url, addresses };
}
