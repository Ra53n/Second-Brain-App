// feedback.ts — обратная связь после ответа ассистента: «решено / не решено».
//
// Каждая отметка фиксируется в CRM оформленным обращением (тикетом):
//   • не решено → тикет open (поддержка увидит его в админке и продолжит);
//   • решено   → тикет closed (обращение зафиксировано как закрытое ассистентом).
// Если чат уже привязан к тикету — обновляется он (статус + комментарий),
// иначе создаётся новый с транскриптом диалога. Пользователь тикета — запись
// CRM по email (создаётся при отсутствии): у вошедших email из аккаунта,
// у гостя — из формы «передать в поддержку».

import type { CrmTicket, TicketMessage } from "../domain/types.js";
import type { HistoryMessage } from "../chat/supportChatService.js";
import type { CrmStore } from "./crmStore.js";

/** Сколько последних сообщений диалога сохранять в транскрипте тикета. */
const TRANSCRIPT_LIMIT = 12;
const SUBJECT_MAX = 80;

export interface FeedbackInput {
  resolved: boolean;
  /** email для привязки к CRM (аккаунт или форма гостя). */
  email: string;
  /** Имя для новой CRM-записи (логин/имя из формы; пусто → email). */
  name: string;
  /** Уже привязанный к чату тикет (повторная отметка) или null. */
  ticketId: string | null;
  /** Диалог целиком (роль/текст); используется при создании тикета. */
  history: HistoryMessage[];
  /** Доп. комментарий пользователя из формы (опционально). */
  comment: string;
  at: string;
}

export interface FeedbackOutcome {
  ticket: CrmTicket;
  created: boolean;
}

/** Диалог чата → переписка тикета ([AI]-префикс у ответов ассистента). */
export function historyToTranscript(history: HistoryMessage[], at: string): TicketMessage[] {
  return history.slice(-TRANSCRIPT_LIMIT).map((m) => ({
    author: m.role === "user" ? ("user" as const) : ("support" as const),
    text: m.role === "assistant" ? `[AI] ${m.content}` : m.content,
    at,
  }));
}

export function subjectFromHistory(history: HistoryMessage[]): string {
  const first = history.find((m) => m.role === "user")?.content ?? "Обращение из чата";
  const oneLine = first.replace(/\s+/g, " ").trim();
  return oneLine.length <= SUBJECT_MAX ? oneLine : oneLine.slice(0, SUBJECT_MAX - 1) + "…";
}

/** Применяет отметку к CRM. Бросает только при невозможности записи. */
export function applyFeedback(crm: CrmStore, input: FeedbackInput): FeedbackOutcome {
  const status = input.resolved ? "closed" : "open";
  const note = input.resolved
    ? "Пользователь отметил: вопрос решён ответом ассистента."
    : "Пользователь отметил: вопрос НЕ решён — требуется поддержка." +
      (input.comment ? ` Комментарий: ${input.comment}` : "");

  // Повторная отметка по уже созданному обращению — обновляем его.
  if (input.ticketId) {
    const updated = crm.setTicketStatus(input.ticketId, status, input.at, {
      author: "user",
      text: note,
    });
    if (updated) return { ticket: updated, created: false };
  }

  const user = crm.findOrCreateUserByEmail(input.email, input.name, input.at);
  const transcript = historyToTranscript(input.history, input.at);
  transcript.push({ author: "user", text: note, at: input.at });
  const ticket = crm.createTicket({
    userId: user.id,
    subject: subjectFromHistory(input.history),
    status,
    tags: ["chat"],
    messages: transcript,
    at: input.at,
  });
  return { ticket, created: true };
}
