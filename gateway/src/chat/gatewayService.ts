// gatewayService.ts — оркестратор одного запроса через gateway (тонкий; вся
// решающая логика — в чистых гардах). Путь:
//   input guard → (block? warning без LLM : forward) → DeepSeek → output guard
//   → cost → запись в аудит → ответ.

import { ValidationError, ConfigError } from "../domain/errors.js";
import {
  HttpLlmClient,
  stripModelMarkup,
  type LlmCompletionClient,
  type Usage,
} from "../llm/openaiClient.js";
import { applyInputPolicy, maskSecrets, type Finding } from "../guard/inputGuard.js";
import { checkOutput, type OutputIssue, type OutputVerdict } from "../guard/outputGuard.js";
import { computeCost, pricesFor } from "../cost/pricing.js";
import type { SettingsRepo } from "../store/settingsRepo.js";
import type { AuditRepo } from "../store/auditRepo.js";
import type { FindingRecord, InputAction } from "../domain/types.js";

const BLOCKED_ANSWER = "Ответ не отдан: сработала выходная защита gateway.";
const DAILY_LIMIT_MSG = "Суточный лимит запросов исчерпан. Попробуй завтра.";

export interface ChatParams {
  prompt: string;
  ip?: string;
  /** Известные секреты для output egress-проверки (сценарий «gateway перед lab»). */
  knownSecrets?: string[];
  signal?: AbortSignal;
}

export interface ChatResult {
  answer: string;
  blocked: boolean;
  warning?: string;
  inputAction: InputAction;
  outputVerdict: OutputVerdict;
  outputIssues: OutputIssue[];
  findings: FindingRecord[];
  usage: Usage;
  costUsd: number;
  model: string;
}

export type ClientFactory = (opts: { url: string; apiKey: string }) => LlmCompletionClient;

const ZERO_USAGE: Usage = { promptTokens: 0, completionTokens: 0, totalTokens: 0 };

function toRecords(findings: Finding[]): FindingRecord[] {
  return findings.map((f) => ({ type: f.type, kind: f.kind, encoding: f.encoding }));
}

function preview(text: string, limit = 500): string {
  return text.length <= limit ? text : `${text.slice(0, limit)}…`;
}

export class GatewayService {
  constructor(
    private readonly settings: SettingsRepo,
    private readonly audit: AuditRepo,
    private readonly clientFactory: ClientFactory = (o) => new HttpLlmClient(o),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async chat(params: ChatParams): Promise<ChatResult> {
    const prompt = params.prompt?.trim() ?? "";
    if (!prompt) throw new ValidationError("Пустой промпт");

    const s = this.settings.get();
    const ip = params.ip ?? "";

    const since = new Date(this.now().getTime() - 24 * 3600 * 1000).toISOString();
    if (this.audit.countSince(since) >= s.dailyLimit) {
      throw new ValidationError(DAILY_LIMIT_MSG);
    }

    // ── Input guard ────────────────────────────────────────────────────────────
    const decision = applyInputPolicy(prompt, { default: s.inputPolicy });

    if (decision.action === "block") {
      const findings = toRecords(decision.findings);
      // В аудит — маскированный промпт: сам секрет в БД не пишем даже при блоке.
      const maskedPreview = maskSecrets(prompt, decision.findings).masked;
      this.audit.log({
        ip,
        userPreview: preview(maskedPreview),
        inputFindings: findings,
        inputAction: "block",
        answer: "",
        outputVerdict: "pass",
        outputIssues: [],
        model: s.model,
        ...ZERO_USAGE,
        costUsd: 0,
        blocked: true,
      });
      return {
        answer: decision.warning,
        blocked: true,
        warning: decision.warning,
        inputAction: "block",
        outputVerdict: "pass",
        outputIssues: [],
        findings,
        usage: ZERO_USAGE,
        costUsd: 0,
        model: s.model,
      };
    }

    const inputAction: InputAction = decision.action;
    const findings = toRecords(decision.action === "mask" ? decision.findings : []);
    const forwardedText = decision.text; // при mask — уже замаскирован

    if (!s.llmApiKey) {
      throw new ConfigError("Ключ LLM не задан. Открой /gw/admin и вставь ключ DeepSeek.");
    }

    // ── Вызов модели ────────────────────────────────────────────────────────────
    const client = this.clientFactory({ url: s.llmUrl, apiKey: s.llmApiKey });
    const completion = await client.chat({
      model: s.model,
      messages: [
        { role: "system", content: s.systemPrompt },
        { role: "user", content: forwardedText },
      ],
      temperature: s.temperature,
      maxTokens: s.maxTokens,
      signal: params.signal,
    });
    const rawAnswer = stripModelMarkup(completion.message.content ?? "");
    const usage = completion.usage;

    // ── Output guard ────────────────────────────────────────────────────────────
    const out = checkOutput(rawAnswer, {
      systemPrompt: s.systemPrompt,
      knownSecrets: params.knownSecrets,
    });
    const blocked = out.verdict === "block";
    const answer = blocked ? BLOCKED_ANSWER : out.text;

    // ── Cost + аудит ────────────────────────────────────────────────────────────
    const cost = computeCost(usage, pricesFor(s.model, s.prices));
    this.audit.log({
      ip,
      userPreview: preview(forwardedText),
      inputFindings: findings,
      inputAction,
      answer: preview(answer, 2000),
      outputVerdict: out.verdict,
      outputIssues: out.issues,
      model: s.model,
      promptTokens: usage.promptTokens,
      completionTokens: usage.completionTokens,
      totalTokens: usage.totalTokens,
      costUsd: cost.usd,
      blocked,
    });

    return {
      answer,
      blocked,
      inputAction,
      outputVerdict: out.verdict,
      outputIssues: out.issues,
      findings,
      usage,
      costUsd: cost.usd,
      model: s.model,
    };
  }
}
