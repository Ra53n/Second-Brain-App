// context.ts — общий контекст приложения (репозитории + сервис + admin-токен).

import type { SettingsRepo } from "../store/settingsRepo.js";
import type { AuditRepo } from "../store/auditRepo.js";
import type { GatewayService } from "../chat/gatewayService.js";

export interface AppContext {
  settingsRepo: SettingsRepo;
  auditRepo: AuditRepo;
  gateway: GatewayService;
  apiToken: string;
}
