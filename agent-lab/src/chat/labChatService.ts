// labChatService.ts — один обмен с агентом-мишенью.
//
// Порядок слоёв фиксирован и повторяет цепочку Second Brain:
//   промпт (персона + секрет + правила) → tool-loop → обёртка тул-результатов →
//   egress-guard → детектор утечки → журнал попыток.
// Уровень защиты решает, какие слои включены (см. promptBuilder).

import type { Logger } from "../logger.js";
import { ConfigError } from "../config.js";
import { BusyError, UpstreamError } from "../domain/errors.js";
import { HttpLlmClient, runToolLoop, type ChatMessage, type LlmCompletionClient } from "../llm/openaiClient.js";
import { buildSystemPrompt, egressGuardEnabled, wrapsToolResults } from "../prompt/promptBuilder.js";
import { wrapToolResult } from "../prompt/security.js";
import { neutralize } from "../guard/egress.js";
import { detectLeak } from "../lab/detector.js";
import { makeExecutor, toolDefs, type LabTool } from "../tools/registry.js";
import type { FlagsRepo } from "../lab/flags.js";
import type { SettingsRepo } from "../store/settingsRepo.js";
import type { SessionRepo } from "../store/sessionRepo.js";
import type { AttemptRepo } from "../store/attemptRepo.js";
import type { LabSession } from "../domain/types.js";

const DAY_MS = 24 * 60 * 60 * 1000;

export interface AnswerResult {
  answer: string;
  tools: string[];
  blocked: string[];
  usage: { promptTokens: number; completionTokens: number; totalTokens: number };
}

export interface LabChatDeps {
  settingsRepo: SettingsRepo;
  flagsRepo: FlagsRepo;
  sessionRepo: SessionRepo;
  attemptRepo: AttemptRepo;
  tools: LabTool[];
  logger: Logger;
  now?: () => Date;
  /** Клиент LLM (в тестах — мок вместо HTTP). */
  clientFactory?: (url: string, apiKey: string) => LlmCompletionClient;
}

export class LabChatService {
  private readonly now: () => Date;

  constructor(private readonly deps: LabChatDeps) {
    this.now = deps.now ?? (() => new Date());
  }

  async answer(
    session: LabSession,
    userText: string,
    opts: { onToolCall?: (name: string) => void; signal?: AbortSignal } = {},
  ): Promise<AnswerResult> {
    const settings = this.deps.settingsRepo.get();
    if (!settings.llmApiKey) {
      throw new ConfigError("Ключ LLM не задан — владелец ещё не настроил лабораторию.");
    }
    const spentToday = this.deps.attemptRepo.countSince(new Date(this.now().getTime() - DAY_MS));
    if (spentToday >= settings.dailyExchangeLimit) {
      throw new BusyError("Суточный лимит обращений к лаборатории исчерпан. Загляни завтра.");
    }

    const flags = this.deps.flagsRepo.list();
    const promptFlag = flags.find((f) => f.key === "prompt")?.value ?? "";
    const level = settings.securityLevel;

    const messages: ChatMessage[] = [
      { role: "system", content: buildSystemPrompt({ level, promptFlag }) },
      ...this.deps.sessionRepo.history(session.id).map((m) => ({ role: m.role, content: m.content })),
      { role: "user", content: userText },
    ];

    // Обёртка недоверенных данных включается с уровня normal: на easy агент
    // получает сырой результат инструмента — это и есть baseline для сравнения.
    const rawExecute = makeExecutor(this.deps.tools);
    const tools = [...this.deps.tools];
    const called: string[] = [];
    const execute = async (name: string, argsJSON: string): Promise<string> => {
      const out = await rawExecute(name, argsJSON);
      return wrapsToolResults(level) ? wrapToolResult(name, out) : out;
    };

    const client =
      this.deps.clientFactory?.(settings.llmUrl, settings.llmApiKey) ??
      new HttpLlmClient({ url: settings.llmUrl, apiKey: settings.llmApiKey });

    const loop = await runToolLoop({
      client,
      model: settings.model,
      temperature: settings.temperature,
      maxTokens: settings.maxTokens,
      messages,
      tools: toolDefs(tools),
      maxIterations: settings.maxIterations,
      execute,
      onToolCall: (name) => {
        called.push(name);
        opts.onToolCall?.(name);
      },
      signal: opts.signal,
    });

    const guard = egressGuardEnabled(level)
      ? neutralize(loop.text, flags.map((f) => f.value))
      : { text: loop.text, blocked: [] as string[] };

    const detection = detectLeak(guard.text, flags, guard.blocked);

    this.deps.sessionRepo.appendMessage(session.id, "user", userText);
    this.deps.sessionRepo.appendMessage(session.id, "assistant", guard.text);
    this.deps.attemptRepo.record({
      sessionId: session.id,
      securityLevel: level,
      userText,
      answerText: guard.text,
      tools: called,
      captured: detection.captured,
      quoted: detection.quoted,
      exfiltrated: detection.exfiltrated,
      blocked: guard.blocked,
      usage: loop.usage,
    });

    if (detection.captured.length > 0 || detection.exfiltrated.length > 0) {
      // Владельцу это интересно сразу — попадает в journalctl. Значения флагов
      // в лог не пишем, только ключи.
      this.deps.logger.warn(
        { session: session.id, captured: detection.captured, exfiltrated: detection.exfiltrated, level },
        "флаг утёк",
      );
    }

    return { answer: guard.text, tools: called, blocked: guard.blocked, usage: loop.usage };
  }
}

export { UpstreamError };
