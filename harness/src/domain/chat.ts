// chat.ts — доменные типы чата. Порт модели ChatModels.swift (Chat/ChatMessage)
// на сервер, упрощённый: без RAG/tools, с трейсом execution loop у ответа.

import type { Finding } from "../fsm/types.js";

export type ChatMode = "normal" | "loop";
export type MsgRole = "user" | "assistant";
export type MsgStatus = "done" | "pending" | "failed";

export interface Chat {
  id: string;
  userId: string;
  title: string;
  mode: ChatMode;
  createdAt: string;
  updatedAt: string;
}

/** Компактная запись одной фазы loop — для трейса под ответом. */
export interface LoopPhase {
  phase: string; // generating | verifying | securityReview
  round: number;
  display: string;
  findings: Finding[];
  correctnessIssues: string[];
  gateway: { inputAction: string | null; findingTypes: string[]; outputVerdict: string | null; blocked: boolean };
  pwned: boolean;
  tokens: number; // токены этого вызова (из usage gateway)
  costUsd: number; // стоимость этого вызова (для админ-статистики)
}

/** Трейс прогона execution loop, прикреплённый к ответу ассистента. */
export interface LoopTrace {
  rounds: number;
  outcome: string | null;
  pwned: boolean;
  costUsd: number;
  totalTokens: number; // сумма токенов по всем фазам
  durationMs: number; // wall-clock генерации сообщения
  phases: LoopPhase[];
}

export interface Message {
  id: string;
  chatId: string;
  seq: number;
  role: MsgRole;
  content: string;
  status: MsgStatus;
  generation: number;
  errorText: string | null;
  loop: LoopTrace | null;
  alert: boolean;
  alertKinds: string[];
  createdAt: string;
}

/** Заголовок чата из первого сообщения: первая строка, ≤40 символов. */
export function makeTitle(text: string): string {
  const line = text.split(/\r?\n/)[0]?.trim() ?? "";
  if (!line) return "Новый чат";
  return line.length <= 40 ? line : `${line.slice(0, 40)}…`;
}

const REFUSAL_RE = /не могу выполнить|не выполняю|не буду выполнять|попытк\w* инъекц|это инъекц/i;

/**
 * Считает алерт сообщения (сигнал для админки, аналог «перехвата» gateway).
 * Условие симметрично `input_action != 'allow' OR output_verdict != 'pass'`.
 */
export function computeAlerts(
  loop: LoopTrace | null,
  content: string,
  status: MsgStatus,
): { alert: boolean; kinds: string[] } {
  const kinds = new Set<string>();
  if (loop) {
    if (loop.pwned) kinds.add("pwned");
    if (loop.outcome === "gateway-blocked") kinds.add("blocked");
    for (const p of loop.phases) {
      if (p.pwned) kinds.add("pwned");
      if (p.findings.some((f) => f.severity === "critical" || f.severity === "high")) kinds.add("security-high");
      const gw = p.gateway;
      if (gw.inputAction && gw.inputAction !== "allow") kinds.add("gateway-intercept");
      if (gw.outputVerdict && gw.outputVerdict !== "pass") kinds.add("gateway-intercept");
      if (gw.blocked) kinds.add("blocked");
    }
  }
  if (status === "failed") kinds.add("failed");
  if (REFUSAL_RE.test(content)) kinds.add("refusal");
  return { alert: kinds.size > 0, kinds: [...kinds] };
}
