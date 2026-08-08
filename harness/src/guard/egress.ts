// egress.ts — OutputEgressGuard: детерминированная защита от эксфильтрации в
// ответах LLM. Порт agent-lab/src/guard/egress.ts + модель Swift OutputEgressGuard
// (внешний хост + признак данных в URL). Применяется к КАЖДОМУ ответу модели
// перед записью в журнал и показом в UI, независимо от сговорчивости модели.

const IMAGE_RE = /!\[([^\]]*)\]\(\s*<?(https?:\/\/[^)\s>]+)>?[^)]*\)/gi;
const LINK_RE = /\[([^\]]*)\]\(\s*<?(https?:\/\/[^)\s>]+)>?[^)]*\)/gi;
const BARE_URL_RE = /https?:\/\/[^\s<>"'`)]+/gi;

export interface EgressResult {
  text: string;
  /** Что срезано — уходит в журнал. */
  blocked: string[];
}

/** Варианты записи секрета, которые модель может подставить в адрес. */
export function secretVariants(secret: string): string[] {
  const trimmed = secret.trim();
  if (trimmed.length < 6) return [];
  const raw = Buffer.from(trimmed, "utf8");
  const variants = new Set<string>([
    trimmed,
    trimmed.replace(/-/g, ""),
    encodeURIComponent(trimmed),
    raw.toString("base64"),
    raw.toString("base64").replace(/=+$/, ""),
    raw.toString("base64url"),
    raw.toString("hex"),
    [...trimmed].reverse().join(""),
  ]);
  return [...variants].filter((v) => v.length >= 6).map((v) => v.toLowerCase());
}

function carriesSecret(url: string, variants: string[]): boolean {
  const haystack = url.toLowerCase();
  return variants.some((v) => haystack.includes(v));
}

/** URL несёт данные: непустой query, userinfo, длинный путь или base64/hex-хвост. */
function carriesData(url: string): boolean {
  try {
    const u = new URL(url);
    if (u.search.length > 1) return true;
    if (u.username || u.password) return true;
    if (u.pathname.length > 40) return true;
    const last = u.pathname.split("/").filter(Boolean).pop() ?? "";
    if (last.length > 24 && /^[A-Za-z0-9+/=_-]+$/.test(last)) return true;
    return false;
  } catch {
    return false;
  }
}

const ALLOWED_HOSTS = new Set(["localhost", "127.0.0.1"]);

function hostOf(url: string): string {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return "";
  }
}

function shorten(url: string): string {
  return url.length <= 120 ? url : `${url.slice(0, 117)}…`;
}

/**
 * Снимает каналы эксфильтрации. Внешние markdown-картинки удаляются всегда
 * (автозагрузка = GET на чужой сервер). Ссылки/голые URL — если несут известный
 * секрет ИЛИ признак данных в адресе. Fenced-код не трогаем (данные, не автозагрузка).
 */
export function neutralize(text: string, secrets: string[]): EgressResult {
  const variants = secrets.flatMap(secretVariants);
  const blocked: string[] = [];

  // Разбиваем по тройным бэктикам, чётные сегменты — вне кода, нечётные — код.
  const segments = text.split("```");
  for (let i = 0; i < segments.length; i += 2) {
    let seg = segments[i]!;

    seg = seg.replace(IMAGE_RE, (_full, alt: string, url: string) => {
      const host = hostOf(url);
      if (ALLOWED_HOSTS.has(host)) return _full;
      blocked.push(`картинка ${shorten(url)}`);
      const label = alt.trim();
      return label ? `[внешняя картинка удалена: ${label}]` : "[внешняя картинка удалена]";
    });

    seg = seg.replace(LINK_RE, (full, label: string, url: string) => {
      const host = hostOf(url);
      if (ALLOWED_HOSTS.has(host)) return full;
      if (!carriesSecret(url, variants) && !carriesData(url)) return full;
      blocked.push(`ссылка ${shorten(url)}`);
      const t = label.trim();
      return t ? `${t} (внешняя ссылка удалена: ${host})` : `[ссылка удалена: ${host}]`;
    });

    seg = seg.replace(BARE_URL_RE, (url: string) => {
      const host = hostOf(url);
      if (ALLOWED_HOSTS.has(host)) return url;
      if (!carriesSecret(url, variants) && !carriesData(url)) return url;
      blocked.push(`ссылка ${shorten(url)}`);
      return "[ссылка удалена]";
    });

    segments[i] = seg;
  }

  return { text: segments.join("```"), blocked };
}
