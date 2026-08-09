// orchestrator.ts — прогон execution loop для ОДНОГО сообщения чата. Каждая фаза —
// вызов gateway (/gw/chat); своего LLM-ключа у чата нет. Пишет компактный трейс фаз
// в message.loop_json, финальный результат — в message.content. Дисциплина как в
// ChatViewModel+AgentRun: переходы только в редьюсере, egress + детект канарейки на
// каждом ответе, защита поколением после каждого await.

import { apply } from "../fsm/reducer.js";
import {
  buildGenerationPrompt,
  buildVerifyPrompt,
  buildSecurityPrompt,
  buildNormalPrompt,
  parseCorrectness,
  parseFindings,
  JSON_RETRY,
} from "../fsm/prompts.js";
import type { CorrectnessVerdict, Finding, PhaseEvent, RunContext } from "../fsm/types.js";
import { neutralize } from "../guard/egress.js";
import type { GatewayClient, GatewayMeta, GatewayReply } from "./gwClient.js";
import type { LoopPhase, LoopTrace, MsgStatus, Source } from "../domain/chat.js";
import { computeAlerts } from "../domain/chat.js";
import { retrieveContext } from "./retrieval.js";
import type { TavilyClient } from "./tavily.js";
import type { ChatsRepo } from "../store/chatsRepo.js";

export interface OrchestratorDeps {
  repo: ChatsRepo;
  gateway: GatewayClient;
  tavily: TavilyClient;
  canary: string;
}

const MAX_ROUNDS = 4;

/** Финализирует сообщение: считает алерт и пишет с защитой поколением. */
function finalize(
  deps: OrchestratorDeps,
  msgId: string,
  generation: number,
  patch: { content?: string; status: MsgStatus; errorText?: string | null; loop: LoopTrace | null },
): boolean {
  const a = computeAlerts(patch.loop, patch.content ?? "", patch.status);
  return deps.repo.updateMessage(msgId, generation, { ...patch, alert: a.alert, alertKinds: a.kinds });
}

const detectCanary = (answer: string, canary: string): boolean => canary.length > 0 && answer.includes(canary);

function freshContext(msgId: string, userText: string, startedAt: string): RunContext {
  return {
    id: msgId,
    taskPrompt: userText,
    state: "generating",
    status: "running",
    round: 1,
    maxRounds: MAX_ROUNDS,
    result: "",
    correctness: null,
    findings: [],
    warnings: [],
    feedback: "",
    outcome: null,
    errorText: null,
    pwned: false,
    costUsd: 0,
    startedAt,
  };
}

function finalContent(ctx: RunContext): string {
  switch (ctx.outcome) {
    case "gateway-blocked":
      return "Запрос заблокирован выходной защитой gateway.";
    case "verdict-unparsed":
      return ctx.result || "Не удалось завершить проверку результата.";
    case "stopped-limit":
      return (ctx.result || "Результат не готов.") + "\n\n_(Проверки не сошлись за лимит кругов — показан последний вариант.)_";
    default:
      return ctx.result;
  }
}

/** Прогоняет loop для сообщения msgId. Наружу не бросает. */
export async function runLoopForMessage(
  deps: OrchestratorDeps,
  msgId: string,
  userText: string,
  dialog: string,
  webSearch: boolean,
  startedAt: string,
  generation: number,
): Promise<void> {
  let ctx = freshContext(msgId, userText, startedAt);
  const phases: LoopPhase[] = [];
  const t0 = Date.now();
  let sources: Source[] = [];

  const trace = (): LoopTrace => ({
    rounds: ctx.round,
    outcome: ctx.outcome,
    pwned: ctx.pwned,
    costUsd: phases.reduce((s, p) => s + p.costUsd, 0),
    totalTokens: phases.reduce((s, p) => s + p.tokens, 0),
    durationMs: Date.now() - t0,
    sources,
    phases,
  });

  // Шаг 0: ретрив внешних материалов (парсинг ссылок / веб-поиск) — как контекст.
  let augDialog = dialog;
  try {
    const r = await retrieveContext(deps.tavily, userText, webSearch);
    sources = r.sources;
    augDialog = r.context + dialog;
  } catch {
    /* ретрив не критичен — продолжаем без него */
  }
  if (deps.repo.generationOf(msgId) !== generation) return;

  while (true) {
    if (deps.repo.generationOf(msgId) !== generation) return;

    let res: { event: PhaseEvent; phase: LoopPhase } | null;
    try {
      res = await runPhase(deps, ctx, augDialog, generation);
    } catch (err) {
      // Сбой фазы (напр. 502 gateway под нагрузкой): не теряем работу — если уже
      // есть сгенерированный результат, показываем его как done с пометкой; иначе failed.
      const note = "\n\n_(Проверки не завершились: " + (err as Error).message + ")_";
      if (ctx.result) {
        finalize(deps, msgId, generation, { content: ctx.result + note, status: "done", loop: trace() });
      } else {
        finalize(deps, msgId, generation, { status: "failed", errorText: (err as Error).message, loop: trace() });
      }
      return;
    }
    if (res === null) return; // поколение устарело
    if (deps.repo.generationOf(msgId) !== generation) return;

    const outcome = apply(ctx, res.event);
    ctx = outcome.ctx;
    if (res.phase.pwned) ctx.pwned = true;
    phases.push({ ...res.phase, display: outcome.display });

    if (outcome.isTerminal) {
      finalize(deps, msgId, generation, { content: finalContent(ctx), status: "done", loop: trace() });
      return;
    }
    // прогресс: обновляем трейс, статус остаётся pending
    if (!deps.repo.updateMessage(msgId, generation, { status: "pending", loop: trace() })) return;
  }
}

/** Обычный режим: один вызов gateway с историей, egress, запись ответа. */
export async function runNormalForMessage(
  deps: OrchestratorDeps,
  msgId: string,
  userText: string,
  dialog: string,
  webSearch: boolean,
  generation: number,
): Promise<void> {
  const t0 = Date.now();
  let sources: Source[] = [];
  let augDialog = dialog;
  try {
    const r = await retrieveContext(deps.tavily, userText, webSearch);
    sources = r.sources;
    augDialog = r.context + dialog;
  } catch {
    /* ретрив не критичен */
  }
  const prompt = buildNormalPrompt(augDialog, userText);
  let reply: GatewayReply;
  try {
    reply = await deps.gateway.chat(prompt);
  } catch (err) {
    finalize(deps, msgId, generation, { status: "failed", errorText: (err as Error).message, loop: null });
    return;
  }
  if (deps.repo.generationOf(msgId) !== generation) return;

  const pwned = detectCanary(reply.answer, deps.canary);
  const guarded = neutralize(reply.answer, [deps.canary].filter(Boolean));
  const meta: GatewayMeta = reply.meta ?? {};
  const tokens = meta.usage?.totalTokens ?? 0;
  const content = reply.blocked ? "Запрос заблокирован выходной защитой gateway." : guarded.text;
  // У обычного ответа тоже кладём мини-трейс: что поймал gateway на этом вызове.
  const loop: LoopTrace = {
    rounds: 1,
    outcome: reply.blocked ? "gateway-blocked" : "done",
    pwned,
    costUsd: meta.costUsd ?? 0,
    totalTokens: tokens,
    durationMs: Date.now() - t0,
    sources,
    phases: [
      {
        phase: "generating",
        round: 1,
        display: "Ответ готов.",
        findings: [],
        correctnessIssues: [],
        gateway: {
          inputAction: meta.inputAction ?? null,
          findingTypes: [...new Set((meta.findings ?? []).map((f) => f.type ?? "?"))],
          outputVerdict: meta.outputVerdict ?? null,
          blocked: reply.blocked,
        },
        pwned,
        tokens,
        costUsd: meta.costUsd ?? 0,
      },
    ],
  };
  finalize(deps, msgId, generation, { content, status: "done", loop });
}

async function runPhase(
  deps: OrchestratorDeps,
  ctx: RunContext,
  dialog: string,
  generation: number,
): Promise<{ event: PhaseEvent; phase: LoopPhase } | null> {
  switch (ctx.state) {
    case "generating":
      return phaseGenerate(deps, ctx, dialog, generation);
    case "verifying":
      return phaseVerify(deps, ctx, generation);
    case "securityReview":
      return phaseReview(deps, ctx, generation);
    default:
      throw new Error(`нежданная фаза ${ctx.state}`);
  }
}

async function phaseGenerate(deps: OrchestratorDeps, ctx: RunContext, dialog: string, generation: number) {
  const prompt = buildGenerationPrompt(ctx, dialog);
  const reply = await deps.gateway.chat(prompt);
  if (deps.repo.generationOf(ctx.id) !== generation) return null;

  const secrets = [deps.canary].filter(Boolean);
  const guarded = neutralize(reply.answer, secrets);
  const pwned = detectCanary(reply.answer, deps.canary);
  const result = reply.blocked ? null : guarded.text;

  const event: PhaseEvent = { kind: "generated", result, gatewayBlocked: reply.blocked };
  return { event, phase: phaseOf("generating", ctx, reply, pwned, [], []) };
}

async function phaseVerify(deps: OrchestratorDeps, ctx: RunContext, generation: number) {
  let prompt = buildVerifyPrompt(ctx);
  let verdict: CorrectnessVerdict | null = null;
  let blocked = false;
  let reply: GatewayReply | null = null;
  let pwned = false;

  for (let attempt = 0; attempt < 2; attempt++) {
    reply = await deps.gateway.chat(prompt);
    if (deps.repo.generationOf(ctx.id) !== generation) return null;
    if (reply.blocked) {
      blocked = true;
      break;
    }
    if (detectCanary(reply.answer, deps.canary)) pwned = true;
    verdict = parseCorrectness(reply.answer);
    if (verdict !== null) break;
    prompt = prompt + JSON_RETRY;
  }

  const event: PhaseEvent = { kind: "verified", verdict, gatewayBlocked: blocked };
  const issues = verdict && !verdict.correct ? verdict.issues : [];
  return { event, phase: phaseOf("verifying", ctx, reply, pwned, [], issues) };
}

async function phaseReview(deps: OrchestratorDeps, ctx: RunContext, generation: number) {
  let prompt = buildSecurityPrompt(ctx);
  let findings: Finding[] | null = null;
  let blocked = false;
  let reply: GatewayReply | null = null;
  let pwned = false;

  for (let attempt = 0; attempt < 2; attempt++) {
    reply = await deps.gateway.chat(prompt);
    if (deps.repo.generationOf(ctx.id) !== generation) return null;
    if (reply.blocked) {
      blocked = true;
      break;
    }
    if (detectCanary(reply.answer, deps.canary)) pwned = true;
    findings = parseFindings(reply.answer);
    if (findings !== null) break;
    prompt = prompt + JSON_RETRY;
  }

  const event: PhaseEvent = { kind: "reviewed", findings, gatewayBlocked: blocked };
  return { event, phase: phaseOf("securityReview", ctx, reply, pwned, findings ?? [], []) };
}

function phaseOf(
  phase: string,
  ctx: RunContext,
  reply: GatewayReply | null,
  pwned: boolean,
  findings: Finding[],
  correctnessIssues: string[],
): LoopPhase {
  const meta: GatewayMeta = reply?.meta ?? {};
  return {
    phase,
    round: ctx.round,
    display: "",
    findings,
    correctnessIssues,
    gateway: {
      inputAction: meta.inputAction ?? null,
      findingTypes: [...new Set((meta.findings ?? []).map((f) => f.type ?? "?"))],
      outputVerdict: meta.outputVerdict ?? null,
      blocked: reply?.blocked ?? false,
    },
    pwned,
    tokens: meta.usage?.totalTokens ?? 0,
    costUsd: meta.costUsd ?? 0,
  };
}
