// orchestrator.ts — цикл FSM (I/O-слой). Порт ChatViewModel+AgentRun на сервер.
// Дисциплина: все переходы — в редьюсере; здесь только LLM (через gateway),
// workspace (git, node --check), persist после фазы и защита поколением.

import { apply } from "../fsm/reducer.js";
import {
  buildGenerationPrompt,
  buildSecurityPrompt,
  extractCode,
  JSON_RETRY,
  parseVerdict,
} from "../fsm/prompts.js";
import type { Finding, PhaseEvent, RunContext } from "../fsm/types.js";
import { neutralize } from "../guard/egress.js";
import type { GatewayClient, GatewayMeta, GatewayReply } from "./gwClient.js";
import { Workspace } from "./workspace.js";
import type { RunsRepo, StepRow } from "../store/runsRepo.js";

export interface OrchestratorDeps {
  repo: RunsRepo;
  gateway: GatewayClient;
  workspaceRoot: string;
  canary: string;
}

function mask(text: string, secrets: string[]): string {
  let out = text;
  for (const s of secrets) {
    if (s) out = out.split(s).join("[REDACTED]");
  }
  return out;
}

function preview(text: string, limit = 600): string {
  return text.length <= limit ? text : `${text.slice(0, limit)}…`;
}

/** Один прогон целиком: крутит фазы до терминала/паузы. Ошибки не бросает наружу. */
export async function runToCompletion(deps: OrchestratorDeps, runId: string, generation: number): Promise<void> {
  const { repo, gateway, canary } = deps;
  const ws = new Workspace(deps.workspaceRoot, runId);

  const first = repo.load(runId);
  if (!first || first.status !== "running") return;

  try {
    if (first.round === 1 && first.state === "generating" && first.code === "") {
      await ws.init(); // новый прогон
    } else {
      ws.recoverPlanted(); // resume — не затираем workspace, восстанавливаем плантованные секреты
    }
  } catch (err) {
    fail(repo, runId, generation, `не удалось подготовить workspace: ${(err as Error).message}`);
    return;
  }

  while (true) {
    const ctx = repo.load(runId);
    if (!ctx || ctx.status !== "running") return;

    let event: PhaseEvent;
    let step: Omit<StepRow, "runId"> | null = null;

    try {
      const phase = await runPhase(deps, ws, ctx, generation);
      if (phase === null) return; // поколение устарело — молча выходим
      event = phase.event;
      step = phase.step;
    } catch (err) {
      fail(repo, runId, generation, (err as Error).message);
      return;
    }

    // Поколение могло смениться, пока шёл await фазы.
    if (repo.generationOf(runId) !== generation) return;

    const fresh = repo.load(runId);
    if (!fresh || fresh.status !== "running") return;

    const outcome = apply(fresh, event);
    // Стоимость и флаг pwned накапливаются вне редьюсера (не часть FSM-логики).
    outcome.ctx.costUsd = fresh.costUsd + (step?.costUsd ?? 0);
    if (step?.pwned) outcome.ctx.pwned = true;
    if (step) repo.addStep({ runId, ...step, display: outcome.display });

    if (!repo.save(outcome.ctx, generation)) return; // устаревшее поколение
    if (outcome.isTerminal) return;
  }
}

interface PhaseResult {
  event: PhaseEvent;
  step: Omit<StepRow, "runId"> | null;
}

/** Выполняет I/O текущей фазы. null — поколение устарело во время await. */
async function runPhase(
  deps: OrchestratorDeps,
  ws: Workspace,
  ctx: RunContext,
  generation: number,
): Promise<PhaseResult | null> {
  switch (ctx.state) {
    case "generating":
      return phaseGenerate(deps, ws, ctx, generation);
    case "testing":
      return phaseTest(deps, ws, ctx);
    case "securityReview":
      return phaseReview(deps, ws, ctx, generation);
    case "committing":
      return phaseCommit(ws, ctx);
    default:
      throw new Error(`нежданная фаза ${ctx.state}`);
  }
}

async function phaseGenerate(
  deps: OrchestratorDeps,
  ws: Workspace,
  ctx: RunContext,
  generation: number,
): Promise<PhaseResult | null> {
  const prompt = buildGenerationPrompt(ctx, deps.canary, ws.context());
  const reply = await deps.gateway.chat(prompt);
  if (deps.repo.generationOf(ctx.id) !== generation) return null;

  const secrets = [...ws.plantedSecrets, deps.canary].filter(Boolean);
  const guarded = neutralize(reply.answer, secrets);
  const pwned = detectCanary(reply.answer, deps.canary);
  const { code, truncated } = extractCode(guarded.text);

  const event: PhaseEvent = { kind: "generated", code, truncated, gatewayBlocked: reply.blocked };
  return {
    event,
    step: stepOf("generating", ctx, prompt, guarded.text, secrets, reply, guarded.blocked, pwned, []),
  };
}

async function phaseTest(deps: OrchestratorDeps, ws: Workspace, ctx: RunContext): Promise<PhaseResult> {
  ws.writeCode(ctx.code);
  const res = await ws.check();
  // node --check эхом печатает строку исходника с ошибкой; если там плантованный
  // секрет/канарейка — маскируем перед записью в публично читаемый журнал.
  const secrets = [...ws.plantedSecrets, deps.canary].filter(Boolean);
  const event: PhaseEvent = { kind: "tested", ok: res.ok, errors: res.errors };
  return {
    event,
    step: {
      round: ctx.round,
      phase: "testing",
      display: "",
      promptPreview: "node --check task.js",
      answerPreview: res.ok ? "OK" : preview(mask(res.errors, secrets)),
      findings: [],
      gateway: {},
      egress: [],
      pwned: false,
      costUsd: 0,
    },
  };
}

async function phaseReview(
  deps: OrchestratorDeps,
  ws: Workspace,
  ctx: RunContext,
  generation: number,
): Promise<PhaseResult | null> {
  let prompt = buildSecurityPrompt(ctx, deps.canary);
  const secrets = [...ws.plantedSecrets, deps.canary].filter(Boolean);
  let findings: Finding[] | null = null;
  let blocked = false;
  let lastReply: GatewayReply | null = null;
  let lastGuardedText = "";
  let egressBlocked: string[] = [];
  let pwned = false;

  for (let attempt = 0; attempt < 2; attempt++) {
    const reply = await deps.gateway.chat(prompt);
    if (deps.repo.generationOf(ctx.id) !== generation) return null;
    lastReply = reply;
    if (reply.blocked) {
      blocked = true;
      break;
    }
    const guarded = neutralize(reply.answer, secrets);
    lastGuardedText = guarded.text;
    egressBlocked = guarded.blocked;
    if (detectCanary(reply.answer, deps.canary)) pwned = true;
    findings = parseVerdict(reply.answer);
    if (findings !== null) break;
    prompt = prompt + JSON_RETRY;
  }

  const event: PhaseEvent = { kind: "reviewed", findings, gatewayBlocked: blocked };
  return {
    event,
    step: stepOf(
      "securityReview",
      ctx,
      prompt,
      lastGuardedText || (lastReply?.warning ?? ""),
      secrets,
      lastReply,
      egressBlocked,
      pwned,
      findings ?? [],
    ),
  };
}

async function phaseCommit(ws: Workspace, ctx: RunContext): Promise<PhaseResult> {
  await ws.commit(`${ctx.taskId}: ${ctx.taskTitle} (круг ${ctx.round})`);
  return {
    event: { kind: "committed" },
    step: {
      round: ctx.round,
      phase: "committing",
      display: "",
      promptPreview: "git commit",
      answerPreview: "закоммичено",
      findings: [],
      gateway: {},
      egress: [],
      pwned: false,
      costUsd: 0,
    },
  };
}

function detectCanary(answer: string, canary: string): boolean {
  return canary.length > 0 && answer.includes(canary);
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
): Omit<StepRow, "runId"> {
  const meta: GatewayMeta = reply?.meta ?? {};
  return {
    round: ctx.round,
    phase,
    display: "",
    promptPreview: preview(mask(prompt, secrets)),
    answerPreview: preview(mask(answerText, secrets)),
    findings,
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
