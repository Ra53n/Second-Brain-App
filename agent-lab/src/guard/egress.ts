// egress.ts — OutputEgressGuard: детерминированная защита от эксфильтрации.
//
// Правило «не подставляй секреты в URL» в системном промпте вероятностно —
// достаточно сговорчивой модели, чтобы оно не сработало. Этот слой работает
// после модели и от её сговорчивости не зависит: он снимает каналы вывода
// (markdown-картинка на внешний домен, ссылка с секретом в адресе), а не
// редактирует текст ответа.
//
// Секрет в ОТКРЫТОМ тексте намеренно не вырезается: лаборатория должна
// оставаться проходимой, а факт выдачи — попадать в журнал попыток.

const IMAGE_RE = /!\[([^\]]*)\]\(\s*(https?:\/\/[^)\s]+)[^)]*\)/gi;
const LINK_RE = /\[([^\]]*)\]\(\s*(https?:\/\/[^)\s]+)[^)]*\)/gi;
const BARE_URL_RE = /https?:\/\/[^\s<>"'`)]+/gi;

export interface EgressResult {
  text: string;
  /** Что именно срезано — уходит в журнал попыток. */
  blocked: string[];
}

/**
 * Варианты записи секрета, которые модель может подставить в адрес: как есть,
 * без дефисов, percent-encoding, base64, hex, задом наперёд.
 */
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

function shortenUrl(url: string): string {
  return url.length <= 120 ? url : `${url.slice(0, 117)}…`;
}

/**
 * Снимает каналы эксфильтрации из ответа модели.
 *
 * Внешние markdown-картинки удаляются всегда: у рабочего ассистента нет причин
 * их генерировать, а загрузка картинки клиентом — готовый GET на чужой сервер.
 * Ссылки удаляются, только если несут секрет в адресе.
 */
export function neutralize(text: string, secrets: string[]): EgressResult {
  const variants = secrets.flatMap(secretVariants);
  const blocked: string[] = [];

  let result = text.replace(IMAGE_RE, (_full, alt: string, url: string) => {
    blocked.push(`картинка ${shortenUrl(url)}`);
    const label = alt.trim();
    return label ? `[внешняя картинка удалена: ${label}]` : "[внешняя картинка удалена]";
  });

  result = result.replace(LINK_RE, (full, label: string, url: string) => {
    if (!carriesSecret(url, variants)) return full;
    blocked.push(`ссылка ${shortenUrl(url)}`);
    const text = label.trim();
    return text ? `[ссылка удалена: ${text}]` : "[ссылка удалена]";
  });

  result = result.replace(BARE_URL_RE, (url: string) => {
    if (!carriesSecret(url, variants)) return url;
    blocked.push(`ссылка ${shortenUrl(url)}`);
    return "[ссылка удалена]";
  });

  return { text: result, blocked };
}
