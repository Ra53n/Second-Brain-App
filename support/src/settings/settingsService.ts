// settingsService.ts — настройки сервиса (провайдер/модели/секрет/промпт/RAG),
// задаются из админки. Паттерн write-only секрет (порт из manager-agent):
//  • getPublic() НИКОГДА не отдаёт секрет — только hasLlmKey + llmKeyHint;
//  • update() применяет секрет ТОЛЬКО если он передан непустым.

import type { SettingsRepo } from "../store/settingsRepo.js";
import {
  PROVIDERS,
  type Provider,
  type RagOptions,
  type SupportSettings,
  type SupportSettingsPublic,
  type UpdateSupportSettingsInput,
} from "../domain/types.js";
import { ValidationError } from "../domain/errors.js";

/** Маска секрета: "" если пусто, иначе "…" + последние 4 символа. */
export function maskSecret(secret: string): string {
  if (!secret) return "";
  return `…${secret.slice(-4)}`;
}

export function toPublic(s: SupportSettings): SupportSettingsPublic {
  return {
    provider: s.provider,
    remoteModel: s.remoteModel,
    localModel: s.localModel,
    embedModel: s.embedModel,
    systemPrompt: s.systemPrompt,
    rag: s.rag,
    maxIterations: s.maxIterations,
    hasLlmKey: s.llmApiKey.length > 0,
    llmKeyHint: maskSecret(s.llmApiKey),
    updatedAt: s.updatedAt,
  };
}

/** Кламп RAG-параметров (защита от абсурдных значений из API). */
export function clampRag(base: RagOptions, patch?: Partial<RagOptions>): RagOptions {
  const clamp = (v: number | undefined, lo: number, hi: number, dflt: number) =>
    typeof v === "number" && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : dflt;
  return {
    topK: Math.round(clamp(patch?.topK, 1, 20, base.topK)),
    candidateK: Math.round(clamp(patch?.candidateK, 1, 50, base.candidateK)),
    minScore: clamp(patch?.minScore, 0, 1, base.minScore),
    budgetTokens: Math.round(clamp(patch?.budgetTokens, 100, 8000, base.budgetTokens)),
  };
}

export class SettingsService {
  constructor(private readonly repo: SettingsRepo) {}

  /** Полные настройки С СЕКРЕТАМИ — только для внутреннего использования. */
  getInternal(): SupportSettings {
    return this.repo.get();
  }

  /** Публичные настройки с замаскированным секретом. */
  getPublic(): SupportSettingsPublic {
    return toPublic(this.repo.get());
  }

  /**
   * Частичное обновление. Несекретные поля — если переданы; секрет (llmApiKey) —
   * ТОЛЬКО если передан непустым (пустой = «не менять»).
   */
  update(input: UpdateSupportSettingsInput, now: string): SupportSettingsPublic {
    const current = this.repo.get();
    const next: SupportSettings = { ...current, updatedAt: now };

    if (input.provider !== undefined) {
      if (!PROVIDERS.includes(input.provider as Provider)) {
        throw new ValidationError(`Неизвестный провайдер: ${input.provider}`);
      }
      next.provider = input.provider;
    }
    if (input.remoteModel !== undefined) next.remoteModel = input.remoteModel.trim();
    if (input.localModel !== undefined) next.localModel = input.localModel.trim();
    if (input.embedModel !== undefined) next.embedModel = input.embedModel.trim();
    if (input.systemPrompt !== undefined) next.systemPrompt = input.systemPrompt;
    if (input.rag) next.rag = clampRag(current.rag, input.rag);
    if (typeof input.maxIterations === "number" && Number.isFinite(input.maxIterations)) {
      next.maxIterations = Math.min(10, Math.max(1, Math.round(input.maxIterations)));
    }
    if (typeof input.llmApiKey === "string" && input.llmApiKey.trim().length > 0) {
      next.llmApiKey = input.llmApiKey.trim();
    }

    return toPublic(this.repo.replace(next));
  }
}
