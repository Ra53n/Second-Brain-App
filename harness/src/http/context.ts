// context.ts — зависимости, которые видят маршруты.

import type { RunsRepo } from "../store/runsRepo.js";
import type { RunManager } from "../run/manager.js";

/** Публичный снимок настроек агента для админки (без секретных значений). */
export interface AgentConfigView {
  version: string;
  gwUrl: string;
  model: string;
  maxRounds: number;
  maxTokensHint: string;
  defaultSecure: boolean;
  rateLimitPerMin: number;
  dailyLimit: number;
  canaryEnabled: boolean;
  systemPromptPreview: string;
  tasks: Array<{ id: string; title: string; trap: string }>;
}

export interface AppContext {
  repo: RunsRepo;
  manager: RunManager;
  apiToken: string;
  configView: () => AgentConfigView;
}
