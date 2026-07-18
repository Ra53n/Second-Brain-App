// context.ts — общий контекст приложения (сервисы), прокидываемый в маршруты.

import type { SettingsService } from "../settings/settingsService.js";
import type { McpServersRepo } from "../store/mcpServersRepo.js";
import type { McpHost } from "../mcp/mcpHost.js";
import type { OllamaClient } from "../llm/ollamaClient.js";
import type { SupportChatService } from "../chat/supportChatService.js";
import type { ChatRepo } from "../store/chatRepo.js";
import type { AuthService } from "../auth/authService.js";
import type { KbRepo } from "../store/kbRepo.js";
import type { KbIndexer } from "../rag/indexer.js";
import type { Embedder } from "../rag/embedder.js";
import type { CrmStore } from "../crm/crmStore.js";
import type { SupportSettings } from "../domain/types.js";

export interface AppContext {
  settings: SettingsService;
  mcpServersRepo: McpServersRepo;
  mcpHost: McpHost;
  ollama: OllamaClient;
  chat: SupportChatService;
  chatRepo: ChatRepo;
  auth: AuthService;
  kbRepo: KbRepo;
  kbIndexer: KbIndexer;
  /** Фабрика эмбеддера по настройкам (в тестах — HashingEmbedder). */
  embedderFactory: (s: SupportSettings) => Embedder;
  crm: CrmStore;
  kbDir: string;
  apiToken: string;
  /** Секрет подписи cookie веб-сессий. */
  sessionSecret: string;
  now: () => Date;
}
