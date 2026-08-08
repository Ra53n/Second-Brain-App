// inputGuard.ts — детекция секретов во входящем промпте + маскирование.
//
// Чистое ядро (P1): без сети и диска, тестируется исчерпывающе. Три слоя:
//   1. plain   — regex-паттерны по сырому тексту;
//   2. base64  — декодируем правдоподобные base64-блобы и прогоняем паттерны
//                по расшифровке (секрет спрятан в кодировке);
//   3. joined  — склеиваем конкатенации строковых литералов ("sk-" + "proj-…")
//                и ищем известный префикс ключа через границу склейки.
// Каждая находка несёт диапазон в СЫРОМ тексте, который надо замаскировать.

export type SecretType =
  | "api_key" // ключи OpenAI/DeepSeek/Anthropic/GitHub/AWS/Google/Slack
  | "email"
  | "credit_card"
  | "phone";

export type Encoding = "plain" | "base64" | "joined";

export interface Finding {
  type: SecretType;
  /** Обнаруженное значение (для base64/joined — восстановленное, для отчёта). */
  value: string;
  /** Подтип для лога: openai_key, aws_access_key, github_token и т.п. */
  kind: string;
  encoding: Encoding;
  /** Диапазон в СЫРОМ тексте, подлежащий маскированию. */
  start: number;
  end: number;
}

interface KeySpec {
  kind: string;
  re: RegExp;
}

// Порядок важен: более специфичные префиксы раньше — при пересечении диапазонов
// побеждает первый принятый (см. dedupe ниже).
const KEY_PATTERNS: KeySpec[] = [
  { kind: "anthropic_key", re: /sk-ant-[A-Za-z0-9_-]{16,}/g },
  { kind: "openai_key", re: /sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}/g },
  { kind: "github_token", re: /gh[pousr]_[A-Za-z0-9]{30,}/g },
  { kind: "aws_access_key", re: /(?:AKIA|ASIA)[0-9A-Z]{16}/g },
  { kind: "google_key", re: /AIza[0-9A-Za-z_-]{35}/g },
  { kind: "slack_token", re: /xox[baprs]-[A-Za-z0-9-]{10,}/g },
];

const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
// Кандидат карты: 13–19 цифр, допускаются пробелы/дефисы как разделители групп.
const CARD_RE = /\b(?:\d[ -]?){12,18}\d\b/g;
// Кандидат телефона: опц. «+», группы цифр через пробел/дефис/скобки.
const PHONE_RE = /(?<!\d)\+?\d(?:[\d\s().-]{7,17})\d(?!\d)/g;

// Известные префиксы ключей для laxного поиска по склейке (короткий хвост ок:
// сам факт конкатенации префикса ключа через границу литералов — уже сигнал).
const KEY_PREFIXES: Array<{ kind: string; re: RegExp }> = [
  { kind: "anthropic_key", re: /sk-ant-[A-Za-z0-9_-]{2,}/ },
  { kind: "openai_key", re: /sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{2,}/ },
  { kind: "github_token", re: /gh[pousr]_[A-Za-z0-9]{2,}/ },
  { kind: "aws_access_key", re: /(?:AKIA|ASIA)[0-9A-Z]{2,}/ },
  { kind: "google_key", re: /AIza[0-9A-Za-z_-]{2,}/ },
];

/** Проверка Луна — отсекает случайные 16-значные числа от номеров карт. */
export function luhnValid(digits: string): boolean {
  const d = digits.replace(/\D/g, "");
  if (d.length < 13 || d.length > 19) return false;
  let sum = 0;
  let dbl = false;
  for (let i = d.length - 1; i >= 0; i--) {
    let n = d.charCodeAt(i) - 48;
    if (dbl) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
    dbl = !dbl;
  }
  return sum % 10 === 0;
}

function overlaps(a: Finding, spans: Array<[number, number]>): boolean {
  return spans.some(([s, e]) => a.start < e && s < a.end);
}

/** plain-слой: прямой прогон паттернов по тексту. */
function scanPlain(text: string): Finding[] {
  const found: Finding[] = [];
  const spans: Array<[number, number]> = [];

  const push = (f: Finding) => {
    if (overlaps(f, spans)) return;
    found.push(f);
    spans.push([f.start, f.end]);
  };

  for (const spec of KEY_PATTERNS) {
    for (const m of text.matchAll(spec.re)) {
      const start = m.index ?? 0;
      push({
        type: "api_key",
        kind: spec.kind,
        value: m[0],
        encoding: "plain",
        start,
        end: start + m[0].length,
      });
    }
  }

  for (const m of text.matchAll(CARD_RE)) {
    const start = m.index ?? 0;
    if (!luhnValid(m[0])) continue;
    push({
      type: "credit_card",
      kind: "credit_card",
      value: m[0].trim(),
      encoding: "plain",
      start,
      end: start + m[0].length,
    });
  }

  for (const m of text.matchAll(EMAIL_RE)) {
    const start = m.index ?? 0;
    push({
      type: "email",
      kind: "email",
      value: m[0],
      encoding: "plain",
      start,
      end: start + m[0].length,
    });
  }

  for (const m of text.matchAll(PHONE_RE)) {
    const start = m.index ?? 0;
    const digits = m[0].replace(/\D/g, "");
    if (digits.length < 10 || digits.length > 15) continue;
    // Требуем «+» или разделитель: голый длинный ряд цифр слишком неоднозначен
    // (может быть id, счётчик, невалидная карта) — иначе ложные срабатывания.
    if (!m[0].startsWith("+") && !/[\s().-]/.test(m[0])) continue;
    push({
      type: "phone",
      kind: "phone",
      value: m[0].trim(),
      encoding: "plain",
      start,
      end: start + m[0].length,
    });
  }

  return found.sort((a, b) => a.start - b.start);
}

const B64_BLOB_RE = /[A-Za-z0-9+/=_-]{16,}/g;

/** base64-слой: декодируем блобы и ищем в расшифровке ключевые паттерны. */
function scanBase64(text: string): Finding[] {
  const found: Finding[] = [];
  for (const m of text.matchAll(B64_BLOB_RE)) {
    const blob = m[0];
    const start = m.index ?? 0;
    let decoded = "";
    try {
      decoded = Buffer.from(blob, "base64").toString("utf8");
    } catch {
      continue;
    }
    // Мусорная расшифровка (не печатаемый ASCII) — не считаем секретом.
    if (!decoded || /[^\x09\x0a\x0d\x20-\x7e]/.test(decoded)) continue;
    for (const spec of KEY_PATTERNS) {
      const km = decoded.match(spec.re);
      if (km) {
        found.push({
          type: "api_key",
          kind: spec.kind,
          value: km[0],
          encoding: "base64",
          start,
          end: start + blob.length,
        });
        break;
      }
    }
  }
  return found;
}

// Конкатенация строковых литералов: "…" + '…' [+ …]. Захватываем всё выражение.
const CONCAT_RE = /(["'])(?:(?!\1).)*\1(?:\s*\+\s*(["'])(?:(?!\2).)*\2)+/g;

/** joined-слой: склеиваем конкатенации и ищем префикс ключа через границу. */
function scanJoined(text: string): Finding[] {
  const found: Finding[] = [];
  for (const m of text.matchAll(CONCAT_RE)) {
    const expr = m[0];
    const start = m.index ?? 0;
    const joined = [...expr.matchAll(/(["'])((?:(?!\1).)*)\1/g)].map((p) => p[2]).join("");
    for (const spec of KEY_PREFIXES) {
      const km = joined.match(spec.re);
      if (km) {
        found.push({
          type: "api_key",
          kind: spec.kind,
          value: joined,
          encoding: "joined",
          start,
          end: start + expr.length,
        });
        break;
      }
    }
  }
  return found;
}

/**
 * Полная детекция: plain + base64 + joined, с дедупликацией пересечений
 * (plain приоритетнее — его диапазоны уже, точнее для маскирования).
 */
export function detectSecrets(text: string): Finding[] {
  const plain = scanPlain(text);
  const spans: Array<[number, number]> = plain.map((f) => [f.start, f.end]);
  const result = [...plain];
  for (const f of [...scanBase64(text), ...scanJoined(text)]) {
    if (overlaps(f, spans)) continue;
    result.push(f);
    spans.push([f.start, f.end]);
  }
  return result.sort((a, b) => a.start - b.start);
}

const MASK: Record<SecretType, string> = {
  api_key: "[REDACTED_API_KEY]",
  email: "[REDACTED_EMAIL]",
  credit_card: "[REDACTED_CARD]",
  phone: "[REDACTED_PHONE]",
};

export interface MaskResult {
  masked: string;
  findings: Finding[];
}

/** Заменяет каждый найденный секрет плейсхолдером по типу (справа налево). */
export function maskSecrets(text: string, findings?: Finding[]): MaskResult {
  const list = (findings ?? detectSecrets(text)).slice().sort((a, b) => b.start - a.start);
  let masked = text;
  for (const f of list) {
    masked = masked.slice(0, f.start) + MASK[f.type] + masked.slice(f.end);
  }
  return { masked, findings: (findings ?? list).slice().sort((a, b) => a.start - b.start) };
}

export type PolicyMode = "block" | "mask";

export interface InputPolicy {
  default: PolicyMode;
  /** Переопределение режима на конкретный тип секрета. */
  byType?: Partial<Record<SecretType, PolicyMode>>;
}

export type InputDecision =
  | { action: "allow"; text: string; findings: [] }
  | { action: "block"; findings: Finding[]; warning: string }
  | { action: "mask"; text: string; findings: Finding[] };

function modeFor(type: SecretType, policy: InputPolicy): PolicyMode {
  return policy.byType?.[type] ?? policy.default;
}

/**
 * Применяет политику к промпту. Если хотя бы один секрет подпадает под `block` —
 * блокируем запрос целиком (в LLM ничего не уходит). Иначе маскируем.
 */
export function applyInputPolicy(text: string, policy: InputPolicy): InputDecision {
  const findings = detectSecrets(text);
  if (findings.length === 0) return { action: "allow", text, findings: [] };

  const anyBlock = findings.some((f) => modeFor(f.type, policy) === "block");
  if (anyBlock) {
    const kinds = [...new Set(findings.map((f) => f.kind))].join(", ");
    return {
      action: "block",
      findings,
      warning: `Запрос заблокирован: во входящем промпте обнаружены секреты (${kinds}). ` +
        `Ничего не отправлено в модель. Убери секреты и повтори.`,
    };
  }
  const { masked } = maskSecrets(text, findings);
  return { action: "mask", text: masked, findings };
}
