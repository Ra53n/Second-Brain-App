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

function normalize(s: string): string {
  return s.toLowerCase().replace(/\s+/g, " ").trim();
}

/**
 * Утечка системного промпта: скользящим окном (≥40 симв.) ищем в ответе любой
 * достаточно длинный дословный кусок системного промпта. Ловит и цитирование
 * фрагмента, а не только целой строки-инструкции.
 */
function detectPromptLeak(text: string, systemPrompt?: string): boolean {
  if (!systemPrompt) return false;
  const sys = normalize(systemPrompt);
  const hay = normalize(text);
  if (sys.length < LEAK_WINDOW) return hay.includes(sys);
  for (let i = 0; i + LEAK_WINDOW <= sys.length; i += 12) {
    if (hay.includes(sys.slice(i, i + LEAK_WINDOW))) return true;
  }
  return false;
}

export function checkOutput(text: string, opts: OutputGuardOptions = {}): OutputResult {
  const issues: OutputIssue[] = [];
  let result = text;
  let verdict: OutputVerdict = "pass";

  // 1. Утечка системного промпта — блокируем полностью.
  if (detectPromptLeak(text, opts.systemPrompt)) {
    issues.push({ kind: "system_prompt_leak", detail: "ответ содержит фрагмент системного промпта" });
    verdict = "block";
  }

  // 2. Опасные команды — блокируем.
  for (const c of DANGEROUS_COMMANDS) {
    if (c.re.test(text)) {
      issues.push({ kind: "dangerous_command", detail: c.detail });
      verdict = "block";
    }
  }

  // Ответ уже блокируется — подчищать текст (шаги 3-4) незачем, наружу он не идёт.
  if (verdict === "block") return { verdict, text, issues };

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
