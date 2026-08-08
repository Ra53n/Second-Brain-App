// reducer.ts — чистое ядро FSM: «контекст + событие фазы → новый контекст».
// Порт AgentPhaseReducer. Синхронный, без I/O. Все переходы — только здесь,
// через legalTransition (precondition по таблице, как ctx.transitioned).

import {
  allows,
  type Finding,
  type Outcome,
  type PhaseEvent,
  type RunContext,
  type RunState,
} from "./types.js";

/** Легальный переход: срыв таблицы — это баг редьюсера, не данные. */
function transition(ctx: RunContext, to: RunState): RunContext {
  if (!allows(ctx.state, to)) {
    throw new Error(`недопустимый переход ${ctx.state} → ${to}`);
  }
  return { ...ctx, state: to };
}

function terminal(ctx: RunContext, outcome: RunContext["outcome"], display: string): Outcome {
  return {
    ctx: { ...ctx, state: "done", status: "finished", outcome },
    display,
    isTerminal: true,
  };
}

const BLOCKING = new Set(["critical", "high"]);

function blocking(findings: Finding[]): Finding[] {
  return findings.filter((f) => BLOCKING.has(f.severity));
}

function minor(findings: Finding[]): Finding[] {
  return findings.filter((f) => !BLOCKING.has(f.severity));
}

/**
 * Применяет результат фазы. Каждый вызов = один свершившийся шаг I/O
 * (генерация/сборка/ревью/коммит), редьюсер только считает следующий контекст.
 */
export function apply(ctx: RunContext, event: PhaseEvent): Outcome {
  switch (ctx.state) {
    case "generating":
      return applyGenerated(ctx, event);
    case "testing":
      return applyTested(ctx, event);
    case "securityReview":
      return applyReviewed(ctx, event);
    case "committing":
      return applyCommitted(ctx, event);
    default:
      throw new Error(`apply вызван в терминальном состоянии ${ctx.state}`);
  }
}

function applyGenerated(ctx: RunContext, event: PhaseEvent): Outcome {
  if (event.kind !== "generated") throw new Error("ожидалось событие generated");

  if (event.gatewayBlocked) {
    return terminal(ctx, "gateway-blocked", "Gateway заблокировал генерацию — стоп.");
  }
  if (event.code === null) {
    // Ответ без кода. Обрыв по maxTokens → просим компактно; иначе — просим блок.
    if (ctx.round >= ctx.maxRounds) {
      return terminal(ctx, "stopped-limit", "Лимит кругов исчерпан без валидного кода.");
    }
    const feedback = event.truncated
      ? "\n\nПрошлый ответ оборвался до закрытия блока кода. Верни файл целиком, но компактно: без комментариев и лишних пустых строк."
      : "\n\nВ прошлом ответе не было блока ```js```. Верни ровно один блок кода.";
    return {
      ctx: { ...ctx, round: ctx.round + 1, feedback },
      display: event.truncated ? "Ответ оборван по лимиту токенов — новый круг." : "В ответе нет кода — новый круг.",
      isTerminal: false,
    };
  }

  const next = transition({ ...ctx, code: event.code, feedback: "" }, "testing");
  return { ctx: next, display: "Код сгенерирован, компилируем.", isTerminal: false };
}

function applyTested(ctx: RunContext, event: PhaseEvent): Outcome {
  if (event.kind !== "tested") throw new Error("ожидалось событие tested");

  if (event.ok) {
    const next = transition({ ...ctx, buildErrors: "" }, "securityReview");
    return { ctx: next, display: "Сборка зелёная, security review.", isTerminal: false };
  }
  // Не собралось — назад на генерацию с ошибками в фидбек (если есть бюджет).
  if (ctx.round >= ctx.maxRounds) {
    return terminal(ctx, "stopped-limit", "Лимит кругов исчерпан, код не собирается.");
  }
  const next = transition(
    {
      ...ctx,
      round: ctx.round + 1,
      buildErrors: event.errors,
      feedback: `\n\nПредыдущая версия не прошла node --check. Ошибки:\n${event.errors}\n\nИсправь и верни файл целиком одним блоком \`\`\`js.`,
    },
    "generating",
  );
  return { ctx: next, display: `Сборка упала (круг ${ctx.round}) — чиним.`, isTerminal: false };
}

function applyReviewed(ctx: RunContext, event: PhaseEvent): Outcome {
  if (event.kind !== "reviewed") throw new Error("ожидалось событие reviewed");

  if (event.gatewayBlocked) {
    return terminal(ctx, "gateway-blocked", "Gateway заблокировал security review — стоп.");
  }
  if (event.findings === null) {
    return terminal(ctx, "verdict-unparsed", "Вердикт security review не распарсился — стоп.");
  }

  const bad = blocking(event.findings);
  const warn = minor(event.findings);

  if (bad.length > 0) {
    if (ctx.round >= ctx.maxRounds) {
      // Бюджет исчерпан — код небезопасен, коммита нет. Терминал.
      return terminal(
        { ...ctx, findings: event.findings },
        "stopped-limit",
        `Лимит кругов исчерпан, осталось ${bad.length} critical/high.`,
      );
    }
    const issues = bad
      .map((f) => `- исправь: ${f.issue} (строка ${f.line ?? "?"}, ${f.severity})`)
      .join("\n");
    const next = transition(
      {
        ...ctx,
        round: ctx.round + 1,
        findings: event.findings,
        feedback: `\n\nSecurity review нашёл проблемы, исправь их:\n${issues}\n\nВерни файл целиком одним блоком \`\`\`js.`,
      },
      "generating",
    );
    return { ctx: next, display: `Security NO-GO: ${bad.length} critical/high — новый круг.`, isTerminal: false };
  }

  // Только Medium/Low → warning, идём на коммит.
  const warnings = [
    ...ctx.warnings,
    ...warn.map((f) => `WARNING [${f.severity}] строка ${f.line ?? "?"}: ${f.issue}`),
  ];
  const next = transition({ ...ctx, findings: event.findings, warnings }, "committing");
  const display = warn.length > 0 ? `Security: ${warn.length} warning (medium/low) — коммитим.` : "Security чисто — коммитим.";
  return { ctx: next, display, isTerminal: false };
}

function applyCommitted(ctx: RunContext, event: PhaseEvent): Outcome {
  if (event.kind !== "committed") throw new Error("ожидалось событие committed");
  return terminal(ctx, "committed", "Закоммичено.");
}
