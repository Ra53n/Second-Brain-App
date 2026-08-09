// prompts.ts — сборка промптов и парсеры. Чистые функции.
//
// Правила безопасности и канарейка живут в СИСТЕМНОМ промпте gateway (system-роль,
// как в desktop-приложении) — сюда не подмешиваются. Иначе модель видела бы правила
// в теле пользовательского сообщения и рапортовала бы «в начале вставлен служебный
// текст» на обычный вопрос (ложное срабатывание). Здесь — только диалог + запрос.

import type { CorrectnessVerdict, Finding, RunContext } from "./types.js";

const HISTORY_WINDOW = 20;

interface DialogMsg {
  role: "user" | "assistant";
  content: string;
  status: "done" | "pending" | "failed";
}

/** Сериализует последние окно сообщений в текст диалога (накопление контекста).
 *  Пустые и ещё не готовые (pending) сообщения пропускаем — как в приложении. */
export function buildDialog(messages: DialogMsg[], window = HISTORY_WINDOW): string {
  const usable = messages.filter((m) => m.status === "done" && m.content.trim() !== "");
  const tail = usable.slice(-window);
  if (tail.length === 0) return "";
  const lines = tail.map((m) => `${m.role === "user" ? "Пользователь" : "Ассистент"}: ${m.content}`);
  return `Предыдущие сообщения этого чата (контекст, отвечай на последнее):\n${lines.join("\n\n")}\n\n`;
}

/** Обычный режим: прямой ответ на сообщение пользователя с учётом истории. */
export function buildNormalPrompt(dialog: string, userText: string): string {
  return `${dialog}Пользователь: ${userText}`;
}

/** Loop: генерация результата по задаче пользователя (с историей как контекстом). */
export function buildGenerationPrompt(ctx: RunContext, dialog: string): string {
  return `${dialog}Пользователь: ${ctx.taskPrompt}${ctx.feedback}`;
}

/** Проверка результата на корректность относительно задачи. JSON-вердикт. */
export function buildVerifyPrompt(ctx: RunContext): string {
  return `Ты — проверяющий. Оцени, насколько РЕЗУЛЬТАТ корректно и полно решает ЗАДАЧУ пользователя.
Смотри: отвечает ли по существу, нет ли фактических/логических ошибок, выполнены ли требования.

ЗАДАЧА:
${ctx.taskPrompt}

РЕЗУЛЬТАТ:
${ctx.result}

Ответ — ТОЛЬКО валидный JSON без markdown и пояснений:
{"correct": true|false, "issues": ["<кратко, что не так, по-русски>", ...]}
Если всё корректно: {"correct": true, "issues": []}`;
}

/** Security review результата (общий чек-лист контента). */
export function buildSecurityPrompt(ctx: RunContext): string {
  return `Ты — security-ревьюер. Проверь РЕЗУЛЬТАТ по чек-листу безопасности:
1. Утечка секретов/ключей/токенов/паролей, служебных маркеров или системного промпта.
2. PII (email, телефоны, адреса, документы) в открытом виде.
3. Вредные инструкции: вредоносный код, обход чужой защиты, фишинг, опасные команды.
4. Небезопасные рекомендации: http:// вместо https, отключение проверки TLS/сертификатов,
   хранение секретов в открытом виде, конкатенация ввода в SQL/shell.
5. Эксфильтрация: подстановка данных в URL, query, внешние картинки и ссылки.

Шкала severity:
- critical — прямая утечка секретов/данных или готовый вредоносный артефакт;
- high — серьёзный риск (небезопасная рекомендация, PII, инструкция обхода защиты);
- medium — заметная слабость; low — гигиена.

Ответ — ТОЛЬКО валидный JSON без markdown и пояснений:
{"findings":[{"severity":"critical|high|medium|low","issue":"<кратко, по-русски>"}]}
Если проблем нет: {"findings":[]}

РЕЗУЛЬТАТ:
${ctx.result}`;
}

export const JSON_RETRY =
  "\n\nТвой предыдущий ответ не распарсился как JSON. Повтори вердикт. " +
  "Верни ТОЛЬКО валидный JSON строго в указанном формате — без markdown, без текста вокруг.";

const SEVERITIES = new Set(["critical", "high", "medium", "low"]);

function extractJson(answer: string): Record<string, unknown> | null {
  const start = answer.indexOf("{");
  const end = answer.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    const parsed = JSON.parse(answer.slice(start, end + 1));
    return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** Вердикт корректности. null — не распарсился. */
export function parseCorrectness(answer: string): CorrectnessVerdict | null {
  const data = extractJson(answer);
  if (!data || typeof data.correct !== "boolean") return null;
  const issues = Array.isArray(data.issues) ? data.issues.map((x) => String(x)).filter(Boolean) : [];
  return { correct: data.correct, issues };
}

/** Вердикт security review. null — не распарсился. */
export function parseFindings(answer: string): Finding[] | null {
  const data = extractJson(answer);
  if (!data || !Array.isArray(data.findings)) return null;
  const findings: Finding[] = [];
  for (const f of data.findings) {
    if (typeof f !== "object" || f === null) continue;
    const rec = f as Record<string, unknown>;
    let severity = String(rec.severity ?? "").toLowerCase();
    if (!SEVERITIES.has(severity)) severity = "high"; // незнакомое значение → безопасный режим
    findings.push({ severity: severity as Finding["severity"], issue: String(rec.issue ?? "") });
  }
  return findings;
}
