// chatManager.ts — жизненный цикл чатов и сообщений с изоляцией по владельцу.
// Все пользовательские методы принимают owner (user.id); чужой чат → NotFound.
// Фоновый прогон на сообщение с защитой поколением; на старте pending → failed.

import { ValidationError, NotFoundError } from "../domain/errors.js";
import type { Chat, ChatMode, Message } from "../domain/chat.js";
import { makeTitle } from "../domain/chat.js";
import { sanitizeUntrusted } from "../guard/security.js";
import { buildDialog } from "../fsm/prompts.js";
import { runLoopForMessage, runNormalForMessage, type OrchestratorDeps } from "./orchestrator.js";
import type { AdminChatRow, AdminMessageRow, AdminStats, ChatsRepo } from "../store/chatsRepo.js";

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

  // ── Чаты пользователя (owner = user.id) ──────────────────────────────────────
  createChat(owner: string): Chat {
    return this.repo.createChat(owner);
  }

  listChats(owner: string): Chat[] {
    return this.repo.listChats(owner);
  }

  getChat(id: string, owner: string): { chat: Chat; messages: Message[] } {
    const chat = this.repo.getChat(id, owner);
    if (!chat) throw new NotFoundError("Чат не найден");
    return { chat, messages: this.repo.messages(id) };
  }

  rename(id: string, owner: string, title: string): Chat {
    if (!this.repo.getChat(id, owner)) throw new NotFoundError("Чат не найден");
    this.repo.rename(id, owner, title);
    return this.repo.getChat(id, owner)!;
  }

  setMode(id: string, owner: string, mode: ChatMode): Chat {
    if (!this.repo.getChat(id, owner)) throw new NotFoundError("Чат не найден");
    this.repo.setMode(id, owner, mode);
    return this.repo.getChat(id, owner)!;
  }

  deleteChat(id: string, owner: string): void {
    if (!this.repo.deleteChat(id, owner)) throw new NotFoundError("Чат не найден");
  }

  getMessage(id: string, owner: string): Message {
    const m = this.repo.getMessageForOwner(id, owner);
    if (!m) throw new NotFoundError("Сообщение не найдено");
    return m;
  }

  // ── Отправка ─────────────────────────────────────────────────────────────────
  send(chatId: string, owner: string, rawContent: string, opts: { webSearch?: boolean } = {}): Message {
    const chat = this.repo.getChat(chatId, owner);
    if (!chat) throw new NotFoundError("Чат не найден");

    const content = sanitizeUntrusted((rawContent ?? "").trim());
    if (!content) throw new ValidationError("Пустое сообщение");

    const prior = this.repo.messages(chatId);
    const dialog = buildDialog(prior);
    const hadUser = prior.some((m) => m.role === "user");

    this.repo.addMessage(chatId, "user", content, "done");
    if (!hadUser) this.repo.rename(chatId, owner, makeTitle(content));

    const assistant = this.repo.addMessage(chatId, "assistant", "", "pending");
    const generation = this.repo.bumpMessageGeneration(assistant.id);
    const startedAt = this.now().toISOString();
    const webSearch = opts.webSearch === true;

    const task =
      chat.mode === "loop"
        ? runLoopForMessage(this.deps, assistant.id, content, dialog, webSearch, startedAt, generation)
        : runNormalForMessage(this.deps, assistant.id, content, dialog, webSearch, generation);

    const p = task.finally(() => {
      if (this.inFlight.get(assistant.id) === p) this.inFlight.delete(assistant.id);
    });
    this.inFlight.set(assistant.id, p);
    return assistant;
  }

  async wait(messageId: string): Promise<void> {
    await this.inFlight.get(messageId);
  }

  // ── Админ-выборки (все пользователи) ─────────────────────────────────────────
  adminChats(): AdminChatRow[] {
    return this.repo.listAllChats();
  }

  adminChatDetail(id: string): { chat: Chat; messages: Message[] } {
    const chat = this.repo.getChatById(id);
    if (!chat) throw new NotFoundError("Чат не найден");
    return { chat, messages: this.repo.messages(id) };
  }

  adminMessages(alertsOnly: boolean): AdminMessageRow[] {
    return this.repo.listAllMessages(alertsOnly);
  }

  adminStats(): AdminStats {
    return this.repo.adminStats();
  }
}
