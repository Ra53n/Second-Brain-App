// chatManager.ts — жизненный цикл чатов и сообщений. Порт роли ChatViewModel:
// newChat/delete/rename/setMode + send (обычный | loop). Фоновый прогон на
// сообщение с защитой поколением; на старте зависшие pending → failed.

import { ValidationError, NotFoundError } from "../domain/errors.js";
import type { Chat, ChatMode, Message } from "../domain/chat.js";
import { makeTitle } from "../domain/chat.js";
import { sanitizeUntrusted } from "../guard/security.js";
import { buildDialog } from "../fsm/prompts.js";
import { runLoopForMessage, runNormalForMessage, type OrchestratorDeps } from "./orchestrator.js";
import type { ChatsRepo } from "../store/chatsRepo.js";

export class ChatManager {
  private readonly inFlight = new Map<string, Promise<void>>();

  constructor(
    private readonly deps: OrchestratorDeps,
    private readonly now: () => Date = () => new Date(),
  ) {}

  private get repo(): ChatsRepo {
    return this.deps.repo;
  }

  recoverOnBoot(): number {
    return this.repo.failPendingOnBoot();
  }

  // ── Чаты ────────────────────────────────────────────────────────────────────
  createChat(): Chat {
    return this.repo.createChat();
  }

  listChats(): Chat[] {
    return this.repo.listChats();
  }

  getChat(id: string): { chat: Chat; messages: Message[] } {
    const chat = this.repo.getChat(id);
    if (!chat) throw new NotFoundError("Чат не найден");
    return { chat, messages: this.repo.messages(id) };
  }

  rename(id: string, title: string): Chat {
    if (!this.repo.getChat(id)) throw new NotFoundError("Чат не найден");
    this.repo.rename(id, title);
    return this.repo.getChat(id)!;
  }

  setMode(id: string, mode: ChatMode): Chat {
    if (!this.repo.getChat(id)) throw new NotFoundError("Чат не найден");
    this.repo.setMode(id, mode);
    return this.repo.getChat(id)!;
  }

  deleteChat(id: string): void {
    this.repo.deleteChat(id);
  }

  getMessage(id: string): Message {
    const m = this.repo.getMessage(id);
    if (!m) throw new NotFoundError("Сообщение не найдено");
    return m;
  }

  // ── Отправка ──────────────────────────────────────────────────────────────────
  send(chatId: string, rawContent: string): Message {
    const chat = this.repo.getChat(chatId);
    if (!chat) throw new NotFoundError("Чат не найден");

    const content = sanitizeUntrusted((rawContent ?? "").trim());
    if (!content) throw new ValidationError("Пустое сообщение");

    // Контекст — история ДО текущего сообщения (накопление).
    const prior = this.repo.messages(chatId);
    const dialog = buildDialog(prior);
    const hadUser = prior.some((m) => m.role === "user");

    this.repo.addMessage(chatId, "user", content, "done");
    if (!hadUser) this.repo.rename(chatId, makeTitle(content)); // заголовок из первого сообщения

    const assistant = this.repo.addMessage(chatId, "assistant", "", "pending");
    const generation = this.repo.bumpMessageGeneration(assistant.id);
    const startedAt = this.now().toISOString();

    const task =
      chat.mode === "loop"
        ? runLoopForMessage(this.deps, assistant.id, content, dialog, startedAt, generation)
        : runNormalForMessage(this.deps, assistant.id, content, dialog, generation);

    const p = task.finally(() => {
      if (this.inFlight.get(assistant.id) === p) this.inFlight.delete(assistant.id);
    });
    this.inFlight.set(assistant.id, p);
    return assistant;
  }

  /** Для тестов/graceful: дождаться завершения фонового прогона сообщения. */
  async wait(messageId: string): Promise<void> {
    await this.inFlight.get(messageId);
  }
}
