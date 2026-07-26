// MessageBubble.swift — пузырь одного сообщения чата (вынесено из
// ChatViews.swift, задача 75).

import AppKit
import MarkdownUI
import SwiftUI

/// Пузырь одного сообщения: markdown-рендер с кликабельными [[wikilinks]],
/// блок «Источники», метрики под ответом и hover-кнопка копирования.
struct MessageBubble: View {
    let message: ChatMessage
    var resolveWikilink: (String) -> URL? = { _ in nil }
    var openNote: (String) -> Void = { _ in }
    /// Постинг ревью в PR (задача 37): кнопка видна при message.reviewTarget.
    var onPostReview: ((ChatMessage) -> Void)? = nil

    @State private var isHovering = false
    /// Кратковременный фидбек «скопировано» (галочка ~1 с).
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(message.role == .user ? "Вы" : "Ассистент")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                agentBadge
                reviewVerdictBadge
            }
            toolCallsBlock
            Markdown(renderedContent)
                .markdownTheme(.docC)
                .textSelection(.enabled)
            fileChangesBlock
            sourcesBlock
            if let metrics = message.metrics {
                Text(metricsLine(metrics))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(metricsTooltip(metrics) ?? "")
            }
            reviewPostRow
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(message.role == .user
                      ? Color.accentColor.opacity(0.08)
                      : Color.secondary.opacity(0.06))
        )
        .overlay(alignment: .topTrailing) { copyButton }
        .onHover { isHovering = $0 }
    }

    /// Бейдж этапа FSM-прогона (задача 35): «Планирование», «Выполнение ·
    /// шаг N/M», «Проверка», «Ответ» — цвет по этапу.
    @ViewBuilder
    private var agentBadge: some View {
        if let state = message.agentState {
            Text(agentBadgeText(state))
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(agentBadgeColor(state).opacity(0.15)))
                .foregroundStyle(agentBadgeColor(state))
        }
    }

    private func agentBadgeText(_ state: AgentTaskState) -> String {
        guard state == .execution, let step = message.agentStep,
              let total = message.agentTotal, total > 0 else { return state.label }
        return "\(state.label) · шаг \(step + 1)/\(total)"
    }

    private func agentBadgeColor(_ state: AgentTaskState) -> Color {
        switch state {
        case .planning: return .blue
        case .execution: return .orange
        case .validation: return .purple
        case .answer: return .green
        }
    }

    /// Бейдж вердикта ревью (задача 37): вычисляется из content — маркер
    /// «ИТОГ РЕВЬЮ:» ставит сама модель, персистить нечего.
    @ViewBuilder
    private var reviewVerdictBadge: some View {
        if message.reviewTarget != nil,
           let verdict = CodeReviewPrompts.parseVerdict(message.content) {
            let approve = verdict == .approve
            Text(approve ? "APPROVE" : "Нужны правки")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill((approve ? Color.green : .orange).opacity(0.15)))
                .foregroundStyle(approve ? Color.green : .orange)
        }
    }

    /// Действие «Отправить комментарием в PR» (задача 37) под итогом ревью;
    /// после успешного постинга — персистентная метка «Отправлено ✓».
    @ViewBuilder
    private var reviewPostRow: some View {
        if let target = message.reviewTarget {
            if let postedAt = message.reviewPostedAt {
                Label("Отправлено в PR #\(String(target.number)) · \(postedAt.formatted(date: .abbreviated, time: .shortened))",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let onPostReview {
                Button {
                    onPostReview(message)
                } label: {
                    Label("Отправить комментарием в PR #\(String(target.number))",
                          systemImage: "paperplane")
                }
                .controlSize(.small)
                .help("Превью и подтверждение перед отправкой на GitHub")
            }
        }
    }

    /// Копирование сообщения (задача 23): сырой markdown в буфер обмена.
    @ViewBuilder
    private var copyButton: some View {
        if (isHovering || justCopied) && !message.content.isEmpty {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                justCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    justCopied = false
                }
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(justCopied ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Скопировать сообщение")
        }
    }

    /// [[wikilinks]] в ответах ассистента → ссылки/пометки галлюцинаций.
    private var renderedContent: String {
        guard !message.content.isEmpty else { return "…" }
        guard message.role == .assistant else { return message.content }
        return ChatWikilinkRenderer.render(message.content) { target in
            resolveWikilink(target) != nil
        }
    }

    /// Вызовы MCP-инструментов (задача 15): свёрнутый блок с именем,
    /// аргументами и результатом каждого вызова.
    @ViewBuilder
    private var toolCallsBlock: some View {
        if let calls = message.toolCalls, !calls.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(calls) { call in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(call.name,
                                  systemImage: call.ok ? "checkmark.circle" : "xmark.circle")
                                .font(.caption.bold())
                                .foregroundStyle(call.ok ? Color.primary : .orange)
                            if !call.argumentsJSON.isEmpty, call.argumentsJSON != "{}" {
                                Text(call.argumentsJSON)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                            Text(call.result)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                                .textSelection(.enabled)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.08)))
                    }
                }
            } label: {
                Label("Инструменты (\(calls.count))", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Применённые файловые операции хода (задача 39): свёрнутый блок с
    /// diff'ами по файлам — отчёт и история изменений.
    @ViewBuilder
    private var fileChangesBlock: some View {
        if let changes = message.fileChanges, !changes.isEmpty {
            FileChangesBlock(changes: changes)
        }
    }

    /// «Источники»: чанки, ушедшие в [RAG_CONTEXT] (задача 14). Клик — заметка;
    /// нерезолвящийся источник (заметку удалили) помечен и не кликабелен.
    @ViewBuilder
    private var sourcesBlock: some View {
        if let sources = message.sources, !sources.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Источники")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(sources) { source in
                    let resolvable = resolveWikilink(source.noteName) != nil
                    Button {
                        openNote(source.noteName)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: resolvable ? "doc.text" : "exclamationmark.triangle")
                            Text(sourceLine(source))
                                .lineLimit(1)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(resolvable ? Color.accentColor : .orange)
                    .disabled(!resolvable)
                }
            }
            .padding(.top, 4)
        }
    }

    private func sourceLine(_ source: RagSource) -> String {
        var line = source.noteName
        if !source.headingPath.isEmpty { line += " · \(source.headingPath)" }
        line += String(format: " · %.0f %%", max(0, source.score) * 100)
        return line
    }

    /// «Провайдер · модель · 1.2 с · 850 ток.» — кто и почём ответил (задача 29).
    private func metricsLine(_ metrics: MessageMetrics) -> String {
        var parts: [String] = []
        if let name = metrics.providerName { parts.append(name) }
        if let model = metrics.model { parts.append(model) }
        parts.append(String(format: "%.1f c", metrics.duration))
        if let total = metrics.totalTokens { parts.append("\(total) ток.") }
        return parts.joined(separator: " · ")
    }

    /// Разбивка токенов для тултипа метрик; nil — usage не пришёл.
    private func metricsTooltip(_ metrics: MessageMetrics) -> String? {
        guard let prompt = metrics.promptTokens,
              let completion = metrics.completionTokens else { return nil }
        return "промпт: \(prompt) ток. · ответ: \(completion) ток."
    }
}
