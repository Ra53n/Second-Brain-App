// context.ts — общий контекст приложения, прокидываемый в маршруты.

import type { SettingsRepo } from "../store/settingsRepo.js";
import type { SessionRepo } from "../store/sessionRepo.js";
import type { AttemptRepo } from "../store/attemptRepo.js";
import type { FlagsRepo } from "../lab/flags.js";
import type { LabChatService } from "../chat/labChatService.js";

export interface AppContext {
  settingsRepo: SettingsRepo;
  sessionRepo: SessionRepo;
  attemptRepo: AttemptRepo;
  flagsRepo: FlagsRepo;
  chat: LabChatService;
  /** Admin bearer-токен из окружения. */
  apiToken: string;
  sessionSecret: string;
  now: () => Date;
}
