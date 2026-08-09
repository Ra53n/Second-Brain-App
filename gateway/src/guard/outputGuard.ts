// outputGuard.ts — проверка ответа модели перед отдачей пользователю.
//
// Чистое ядро (P1). Ловит четыре класса проблем:
//   1. секреты, сгенерированные моделью (галлюцинированные ключи sk-/ghp_/AKIA…);
//   2. утечку системного промпта (модель процитировала свои инструкции);
//   3. эксфильтрацию известного секрета через URL/картинку (egress-слой);
//   4. опасные команды (rm -rf, curl … | sh, fork-бомба и т.п.).
// Вердикт: pass | redact (текст подчищен) | block (не отдаём вовсе).

import { detectSecrets, maskSecrets } from "./inputGuard.js";
import { neutralize } from "./egress.js";

export type OutputVerdict = "pass" | "redact" | "block";

export interface OutputIssue {
  kind: "generated_secret" | "system_prompt_leak" | "secret_exfil_url" | "dangerous_command";
  detail: string;
}

export interface OutputResult {
  verdict: OutputVerdict;
  /** Подчищенный текст (для redact); для block — исходный, наружу не отдаётся. */
  text: string;
  issues: OutputIssue[];
}

export interface OutputGuardOptions {
  /** Известные секреты (канарейки бэкенда) — для egress-проверки URL. */
  knownSecrets?: string[];
  /** Системный промпт — для детекции его утечки в ответе. */
  systemPrompt?: string;
}

const DANGEROUS_COMMANDS: Array<{ re: RegExp; detail: string }> = [
  { re: /\brm\s+-[rf]{1,2}\b/i, detail: "rm -rf" },
  { re: /\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+)?(?:ba)?sh\b/i, detail: "curl|sh" },
  { re: /:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/, detail: "fork-бомба" },
  { re: /\bmkfs\.\w+\b/i, detail: "mkfs" },
  { re: /\bdd\s+if=\S+\s+of=\/dev\/\w+/i, detail: "dd of=/dev" },
  { re: /\bchmod\s+-R\s+777\s+\//i, detail: "chmod -R 777 /" },
];

const LEAK_WINDOW = 40;

// Чувствительны только строки-директивы (что модель не должна раскрывать), а не
// вся персона: иначе честный ответ «кто ты» пересказывает роль и ловится как утечка.
const GUARD_KEYWORDS = /(не раскрыв|инструкц|секрет|не выводи|system\s*prompt|систем\w* промпт|игнорируй|prompt)/i;

function normalize(s: string): string {
  return s.toLowerCase().replace(/\s+/g, " ").trim();
}

/** Разбивает промпт на предложения/строки и оставляет только защищаемые директивы. */
function protectedLines(systemPrompt: string): string[] {
  return systemPrompt
    .split(/(?<=[.!?])\s+|\n+/)
    .map((s) => s.trim())
    .filter((s) => s.length >= 20 && GUARD_KEYWORDS.test(s));
}

/**
 * Утечка системного промпта: скользящим окном (≥40 симв.) ищем в ответе дословный
 * кусок ЗАЩИЩАЕМОЙ директивы промпта. Пересказ роли/персоны не считается утечкой —
 * ловим только выдачу самих инструкций (что и есть реальная атака «покажи промпт»).
 */
function detectPromptLeak(text: string, systemPrompt?: string): boolean {
  if (!systemPrompt) return false;
  const hay = normalize(text);
  for (const line of protectedLines(systemPrompt)) {
    const l = normalize(line);
    if (l.length < LEAK_WINDOW) {
      if (hay.includes(l)) return true;
      continue;
    }
    for (let i = 0; i + LEAK_WINDOW <= l.length; i += 12) {
      if (hay.includes(l.slice(i, i + LEAK_WINDOW))) return true;
    }
  }
  return false;
}

export function checkOutput(text: string, opts: OutputGuardOptions = {}): OutputResult {
  const issues: OutputIssue[] = [];
  let result = text;
  let verdict: OutputVerdict = "pass";

  // 1. Утечка системного промпта — блокируем полностью (реальная атака «покажи промпт»).
  if (detectPromptLeak(text, opts.systemPrompt)) {
    issues.push({ kind: "system_prompt_leak", detail: "ответ содержит фрагмент системного промпта" });
    return { verdict: "block", text, issues };
  }

  // 2. Опасные команды — ВЫРЕЗАЕМ сам вызов, не рушим весь ответ: в чате `curl … | sh`
  //    и т.п. часто легитимная install-инструкция, а не исполняемая команда.
  for (const c of DANGEROUS_COMMANDS) {
    const g = new RegExp(c.re.source, c.re.flags.includes("g") ? c.re.flags : c.re.flags + "g");
    if (g.test(result)) {
      // Сам вызов в видимый текст не возвращаем; что именно вырезали — только в issues.
      result = result.replace(g, "[потенциально опасная команда вырезана]");
      issues.push({ kind: "dangerous_command", detail: c.detail });
      if (verdict === "pass") verdict = "redact";
    }
  }

  // 3. Эксфильтрация известного секрета через URL/картинку — вырезаем.
  if (opts.knownSecrets && opts.knownSecrets.length > 0) {
    const eg = neutralize(result, opts.knownSecrets);
    if (eg.blocked.length > 0) {
      result = eg.text;
      for (const b of eg.blocked) issues.push({ kind: "secret_exfil_url", detail: b });
      if (verdict === "pass") verdict = "redact";
    }
  }

  // 4. Сгенерированные моделью секреты (ключи) — маскируем в тексте.
  const keyFindings = detectSecrets(result).filter((f) => f.type === "api_key");
  if (keyFindings.length > 0) {
    result = maskSecrets(result, keyFindings).masked;
    const kinds = [...new Set(keyFindings.map((f) => f.kind))].join(", ");
    issues.push({ kind: "generated_secret", detail: `ключ в ответе (${kinds})` });
    if (verdict === "pass") verdict = "redact";
  }

  // Сюда доходим только с pass/redact (block вышел раньше) — отдаём подчищенный.
  return { verdict, text: result, issues };
}
