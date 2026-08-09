// chat.ts — доменные типы чата. Порт модели ChatModels.swift (Chat/ChatMessage)
// на сервер, упрощённый: без RAG/tools, с трейсом execution loop у ответа.

import type { Finding } from "../fsm/types.js";

export type ChatMode = "normal" | "loop";
export type MsgRole = "user" | "assistant";
export type MsgStatus = "done" | "pending" | "failed";

export interface Chat {
  id: string;
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
}

/** Трейс прогона execution loop, прикреплённый к ответу ассистента. */
export interface LoopTrace {
  rounds: number;
  outcome: string | null;
  pwned: boolean;
  costUsd: number;
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
  createdAt: string;
}

/** Заголовок чата из первого сообщения: первая строка, ≤40 символов. */
export function makeTitle(text: string): string {
  const line = text.split(/\r?\n/)[0]?.trim() ?? "";
  if (!line) return "Новый чат";
  return line.length <= 40 ? line : `${line.slice(0, 40)}…`;
}
