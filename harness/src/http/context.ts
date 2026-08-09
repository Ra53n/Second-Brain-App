// context.ts — зависимости, которые видят маршруты.

import type { RunsRepo } from "../store/runsRepo.js";
import type { RunManager } from "../run/manager.js";

/** Публичный снимок настроек агента для админки (без секретных значений). */
export interface AgentConfigView {
  version: string;
  gwUrl: string;
  model: string;
  loop: string; // человекочитаемая схема цикла
  maxRounds: number;
  defaultSecure: boolean;
  rateLimitPerMin: number;
  dailyLimit: number;
  canaryEnabled: boolean;
  systemPromptPreview: string;
}

export interface AppContext {
  repo: RunsRepo;
  manager: RunManager;
  apiToken: string;
  configView: () => AgentConfigView;
}
