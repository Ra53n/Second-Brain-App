// settingsRepo.ts — единственная строка настроек сервиса (id=1), С СЕКРЕТАМИ.
// Маскирование и «не затирать пустым секретом» — в settingsService.

import type { DB } from "./db.js";
import {
  DEFAULT_EMBED_MODEL,
  DEFAULT_LOCAL_MODEL,
  DEFAULT_MAX_ITERATIONS,
  DEFAULT_RAG_OPTIONS,
  DEFAULT_REMOTE_MODEL,
  DEFAULT_SUPPORT_SYSTEM_PROMPT,
  type Provider,
  type RagOptions,
  type SupportSettings,
} from "../domain/types.js";

interface SettingsRow {
  id: number;
  provider: string;
  llm_api_key: string;
  remote_model: string;
  local_model: string;
  embed_model: string;
  system_prompt: string;
  rag_json: string;
  max_iterations: number;
  updated_at: string;
}

function parseRag(json: string): RagOptions {
  try {
    const v = JSON.parse(json) as Partial<RagOptions>;
    return { ...DEFAULT_RAG_OPTIONS, ...(v && typeof v === "object" ? v : {}) };
  } catch {
    return { ...DEFAULT_RAG_OPTIONS };
  }
}

export class SettingsRepo {
  constructor(private readonly db: DB) {}

  get(): SupportSettings {
    const row = this.db.prepare(`SELECT * FROM settings WHERE id=1`).get() as
      | SettingsRow
      | undefined;
    return {
      provider: (row?.provider as Provider) ?? "ollama",
      llmApiKey: row?.llm_api_key ?? "",
      remoteModel: row?.remote_model ?? DEFAULT_REMOTE_MODEL,
      localModel: row?.local_model ?? DEFAULT_LOCAL_MODEL,
      embedModel: row?.embed_model ?? DEFAULT_EMBED_MODEL,
      systemPrompt: row?.system_prompt || DEFAULT_SUPPORT_SYSTEM_PROMPT,
      rag: parseRag(row?.rag_json ?? "{}"),
      maxIterations: row?.max_iterations ?? DEFAULT_MAX_ITERATIONS,
      updatedAt: row?.updated_at ?? "",
    };
  }

  replace(s: SupportSettings): SupportSettings {
    this.db
      .prepare(
        `UPDATE settings SET
           provider=@provider, llm_api_key=@llm_api_key, remote_model=@remote_model,
           local_model=@local_model, embed_model=@embed_model, system_prompt=@system_prompt,
           rag_json=@rag_json, max_iterations=@max_iterations, updated_at=@updated_at
         WHERE id=1`,
      )
      .run({
        provider: s.provider,
        llm_api_key: s.llmApiKey,
        remote_model: s.remoteModel,
        local_model: s.localModel,
        embed_model: s.embedModel,
        system_prompt: s.systemPrompt,
        rag_json: JSON.stringify(s.rag),
        max_iterations: s.maxIterations,
        updated_at: s.updatedAt,
      });
    return s;
  }
}
