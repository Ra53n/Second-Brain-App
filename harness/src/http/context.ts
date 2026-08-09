// context.ts — зависимости, которые видят маршруты.

import type { ChatsRepo } from "../store/chatsRepo.js";
import type { ChatManager } from "../run/chatManager.js";
import type { AuthService } from "../auth/authService.js";

/** Публичный снимок настроек агента для админки (без секретных значений). */
export interface AgentConfigView {
  version: string;
  gwUrl: string;
  model: string;
  loop: string; // человекочитаемая схема цикла
  modes: string; // доступные режимы чата
  maxRounds: number;
  historyWindow: number;
  rateLimitPerMin: number;
  canaryEnabled: boolean;
  systemPromptPreview: string;
}

export interface AppContext {
  repo: ChatsRepo;
  manager: ChatManager;
  auth: AuthService;
  apiToken: string;
  sessionSecret: string;
  webSearchEnabled: boolean;
  configView: () => AgentConfigView;
}
