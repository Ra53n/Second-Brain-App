// orchestrator.ts — цикл execution loop (I/O-слой). Каждая фаза — один вызов
// gateway (/gw/chat); своего LLM-ключа у чата нет. Дисциплина: все переходы — в
// редьюсере; здесь только LLM, egress-guard, детект канарейки, persist и защита
// поколением. Порт ChatViewModel+AgentRun на сервер, без исполнения кода.

import { apply } from "../fsm/reducer.js";
import {
  buildGenerationPrompt,
  buildVerifyPrompt,
  buildSecurityPrompt,
  parseCorrectness,
  parseFindings,
  JSON_RETRY,
} from "../fsm/prompts.js";
import type { CorrectnessVerdict, Finding, PhaseEvent, RunContext } from "../fsm/types.js";
import { neutralize } from "../guard/egress.js";
import type { GatewayClient, GatewayMeta, GatewayReply } from "./gwClient.js";
import type { RunsRepo, StepRow } from "../store/runsRepo.js";

export interface OrchestratorDeps {
  repo: RunsRepo;
  gateway: GatewayClient;
  canary: string;
}

function mask(text: string, secrets: string[]): string {
  let out = text;
  for (const s of secrets) if (s) out = out.split(s).join("[REDACTED]");
  return out;
}

function preview(text: string, limit = 800): string {
  return text.length <= limit ? text : `${text.slice(0, limit)}…`;
}

const detectCanary = (answer: string, canary: string): boolean => canary.length > 0 && answer.includes(canary);

/** Один прогон целиком: крутит фазы до терминала/паузы. Наружу не бросает. */
export async function runToCompletion(deps: OrchestratorDeps, runId: string, generation: number): Promise<void> {
  const { repo } = deps;
  const first = repo.load(runId);
  if (!first || first.status !== "running") return;

  while (true) {
    const ctx = repo.load(runId);
    if (!ctx || ctx.status !== "running") return;

    let phase: { event: PhaseEvent; step: Omit<StepRow, "runId"> } | null;
    try {
      phase = await runPhase(deps, ctx, generation);
    } catch (err) {
      fail(repo, runId, generation, (err as Error).message);
      return;
    }
    if (phase === null) return; // поколение устарело

    if (repo.generationOf(runId) !== generation) return;
    const fresh = repo.load(runId);
    if (!fresh || fresh.status !== "running") return;

    const outcome = apply(fresh, phase.event);
    outcome.ctx.costUsd = fresh.costUsd + phase.step.costUsd;
    if (phase.step.pwned) outcome.ctx.pwned = true;
    repo.addStep({ runId, ...phase.step, display: outcome.display });

    if (!repo.save(outcome.ctx, generation)) return;
    if (outcome.isTerminal) return;
  }
}

async function runPhase(
  deps: OrchestratorDeps,
  ctx: RunContext,
  generation: number,
): Promise<{ event: PhaseEvent; step: Omit<StepRow, "runId"> } | null> {
  switch (ctx.state) {
    case "generating":
      return phaseGenerate(deps, ctx, generation);
    case "verifying":
      return phaseVerify(deps, ctx, generation);
    case "securityReview":
      return phaseReview(deps, ctx, generation);
    default:
      throw new Error(`нежданная фаза ${ctx.state}`);
  }
}

async function phaseGenerate(deps: OrchestratorDeps, ctx: RunContext, generation: number) {
  const prompt = buildGenerationPrompt(ctx, deps.canary);
  const reply = await deps.gateway.chat(prompt);
  if (deps.repo.generationOf(ctx.id) !== generation) return null;

  const secrets = [deps.canary].filter(Boolean);
  const guarded = neutralize(reply.answer, secrets);
  const pwned = detectCanary(reply.answer, deps.canary);
  const result = reply.blocked ? null : guarded.text;

  const event: PhaseEvent = { kind: "generated", result, gatewayBlocked: reply.blocked };
  return { event, step: stepOf("generating", ctx, prompt, guarded.text, secrets, reply, guarded.blocked, pwned, [], []) };
}

async function phaseVerify(deps: OrchestratorDeps, ctx: RunContext, generation: number) {
  let prompt = buildVerifyPrompt(ctx, deps.canary);
  const secrets = [deps.canary].filter(Boolean);
  let verdict: CorrectnessVerdict | null = null;
  let blocked = false;
  let reply: GatewayReply | null = null;
  let pwned = false;

  let egressBlocked: string[] = [];
  let answerText = "";
  for (let attempt = 0; attempt < 2; attempt++) {
    reply = await deps.gateway.chat(prompt);
    if (deps.repo.generationOf(ctx.id) !== generation) return null;
    if (reply.blocked) {
      blocked = true;
      break;
    }
    if (detectCanary(reply.answer, deps.canary)) pwned = true;
    // Egress-guard на КАЖДОМ ответе модели (контракт egress.ts), даже на вердикте.
    const guarded = neutralize(reply.answer, secrets);
    answerText = guarded.text;
    egressBlocked = guarded.blocked;
    verdict = parseCorrectness(reply.answer);
    if (verdict !== null) break;
    prompt = prompt + JSON_RETRY;
  }

  const event: PhaseEvent = { kind: "verified", verdict, gatewayBlocked: blocked };
  const corrIssues = verdict && !verdict.correct ? verdict.issues.map((i) => ({ severity: "info", issue: i })) : [];
  return { event, step: stepOf("verifying", ctx, prompt, answerText, secrets, reply, egressBlocked, pwned, [], corrIssues) };
}

async function phaseReview(deps: OrchestratorDeps, ctx: RunContext, generation: number) {
  let prompt = buildSecurityPrompt(ctx, deps.canary);
  const secrets = [deps.canary].filter(Boolean);
  let findings: Finding[] | null = null;
  let blocked = false;
  let reply: GatewayReply | null = null;
  let pwned = false;

  let egressBlocked: string[] = [];
  let answerText = "";
  for (let attempt = 0; attempt < 2; attempt++) {
    reply = await deps.gateway.chat(prompt);
    if (deps.repo.generationOf(ctx.id) !== generation) return null;
    if (reply.blocked) {
      blocked = true;
      break;
    }
    if (detectCanary(reply.answer, deps.canary)) pwned = true;
    const guarded = neutralize(reply.answer, secrets);
    answerText = guarded.text;
    egressBlocked = guarded.blocked;
    findings = parseFindings(reply.answer);
    if (findings !== null) break;
    prompt = prompt + JSON_RETRY;
  }

  const event: PhaseEvent = { kind: "reviewed", findings, gatewayBlocked: blocked };
  return { event, step: stepOf("securityReview", ctx, prompt, answerText, secrets, reply, egressBlocked, pwned, findings ?? [], []) };
}

function stepOf(
  phase: string,
  ctx: RunContext,
  prompt: string,
  answerText: string,
  secrets: string[],
  reply: GatewayReply | null,
  egress: string[],
  pwned: boolean,
  findings: Finding[],
  correctnessIssues: Array<{ severity: string; issue: string }>,
): Omit<StepRow, "runId"> {
  const meta: GatewayMeta = reply?.meta ?? {};
  return {
    round: ctx.round,
    phase,
    display: "",
    promptPreview: preview(mask(prompt, secrets)),
    answerPreview: preview(mask(answerText, secrets)),
    findings,
    correctnessIssues,
    gateway: {
      inputAction: meta.inputAction ?? null,
      outputVerdict: meta.outputVerdict ?? null,
      findingTypes: [...new Set((meta.findings ?? []).map((f) => f.type ?? "?"))],
      blocked: reply?.blocked ?? false,
    },
    egress,
    pwned,
    costUsd: meta.costUsd ?? 0,
  };
}

function fail(repo: RunsRepo, runId: string, generation: number, message: string): void {
  const ctx = repo.load(runId);
  if (!ctx) return;
  repo.save({ ...ctx, status: "failed", errorText: message }, generation);
}
