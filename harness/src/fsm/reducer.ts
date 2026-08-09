// reducer.ts — чистое ядро execution loop: «контекст + событие фазы → новый
// контекст». Синхронный, без I/O. Все переходы только здесь, через transition
// (precondition по таблице). Порт AgentPhaseReducer.

import {
  allows,
  type Finding,
  type Outcome,
  type PhaseEvent,
  type RunContext,
  type RunState,
} from "./types.js";

function transition(ctx: RunContext, to: RunState): RunContext {
  if (!allows(ctx.state, to)) throw new Error(`недопустимый переход ${ctx.state} → ${to}`);
  return { ...ctx, state: to };
}

function terminal(ctx: RunContext, outcome: RunContext["outcome"], display: string): Outcome {
  return { ctx: { ...ctx, state: "done", status: "finished", outcome }, display, isTerminal: true };
}

const BLOCKING = new Set(["critical", "high"]);
const blocking = (f: Finding[]): Finding[] => f.filter((x) => BLOCKING.has(x.severity));
const minor = (f: Finding[]): Finding[] => f.filter((x) => !BLOCKING.has(x.severity));

/** Применяет результат фазы. Один вызов = один свершившийся шаг I/O. */
export function apply(ctx: RunContext, event: PhaseEvent): Outcome {
  switch (ctx.state) {
    case "generating":
      return applyGenerated(ctx, event);
    case "verifying":
      return applyVerified(ctx, event);
    case "securityReview":
      return applyReviewed(ctx, event);
    default:
      throw new Error(`apply вызван в терминальном состоянии ${ctx.state}`);
  }
}

function applyGenerated(ctx: RunContext, event: PhaseEvent): Outcome {
  if (event.kind !== "generated") throw new Error("ожидалось событие generated");
  if (event.gatewayBlocked) return terminal(ctx, "gateway-blocked", "Gateway заблокировал генерацию — стоп.");
  if (event.result === null || event.result.trim() === "") {
    if (ctx.round >= ctx.maxRounds) return terminal(ctx, "stopped-limit", "Лимит кругов исчерпан без результата.");
    return {
      ctx: { ...ctx, round: ctx.round + 1, feedback: "\n\nПрошлый ответ был пуст. Дай содержательный результат." },
      display: "Пустой ответ — новый круг.",
      isTerminal: false,
    };
  }
  const next = transition({ ...ctx, result: event.result, feedback: "" }, "verifying");
  return { ctx: next, display: "Результат готов, проверяю корректность.", isTerminal: false };
}

function applyVerified(ctx: RunContext, event: PhaseEvent): Outcome {
  if (event.kind !== "verified") throw new Error("ожидалось событие verified");
  if (event.gatewayBlocked) return terminal(ctx, "gateway-blocked", "Gateway заблокировал проверку — стоп.");
  if (event.verdict === null) return terminal(ctx, "verdict-unparsed", "Вердикт проверки корректности не распарсился — стоп.");

  if (event.verdict.correct) {
    const next = transition({ ...ctx, correctness: event.verdict }, "securityReview");
    return { ctx: next, display: "Корректно, проверяю безопасность.", isTerminal: false };
  }
  // Не корректно — назад на генерацию с замечаниями (если есть бюджет).
  if (ctx.round >= ctx.maxRounds) {
    return terminal({ ...ctx, correctness: event.verdict }, "stopped-limit", "Лимит кругов исчерпан, результат не признан корректным.");
  }
  const issues = event.verdict.issues.map((i) => `- ${i}`).join("\n") || "- результат не соответствует задаче";
  const next = transition(
    { ...ctx, round: ctx.round + 1, correctness: event.verdict, feedback: `\n\nПроверка нашла проблемы корректности, исправь:\n${issues}` },
    "generating",
  );
  return { ctx: next, display: `Проверка: не корректно (${event.verdict.issues.length} замеч.) — новый круг.`, isTerminal: false };
}

function applyReviewed(ctx: RunContext, event: PhaseEvent): Outcome {
  if (event.kind !== "reviewed") throw new Error("ожидалось событие reviewed");
  if (event.gatewayBlocked) return terminal(ctx, "gateway-blocked", "Gateway заблокировал security review — стоп.");
  if (event.findings === null) return terminal(ctx, "verdict-unparsed", "Вердикт security review не распарсился — стоп.");

  const bad = blocking(event.findings);
  const warn = minor(event.findings);

  if (bad.length > 0) {
    if (ctx.round >= ctx.maxRounds) {
      return terminal({ ...ctx, findings: event.findings }, "stopped-limit", `Лимит кругов исчерпан, осталось ${bad.length} critical/high.`);
    }
    const issues = bad.map((f) => `- исправь: ${f.issue} (${f.severity})`).join("\n");
    const next = transition(
      { ...ctx, round: ctx.round + 1, findings: event.findings, feedback: `\n\nSecurity review нашёл проблемы, устрани их в результате:\n${issues}` },
      "generating",
    );
    return { ctx: next, display: `Security NO-GO: ${bad.length} critical/high — новый круг.`, isTerminal: false };
  }

  const warnings = [...ctx.warnings, ...warn.map((f) => `WARNING [${f.severity}]: ${f.issue}`)];
  const done = terminal({ ...ctx, findings: event.findings, warnings }, "done", warn.length > 0 ? `Security: ${warn.length} warning (medium/low) — готово.` : "Security чисто — готово.");
  return done;
}
