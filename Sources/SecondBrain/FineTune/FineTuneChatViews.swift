// FineTuneChatViews.swift — вкладка «Чат» раздела «Тюнинг» (задача 85): мини-чат
// оценки уверенности инференса. Датасет `meetings` — единственный со строгим
// JSON-контрактом, для остальных вкладка — заглушка.
//
// AX-инвариант модуля (FineTuneTabBar.swift): кнопки контент-области не отдают
// System Events ни name, ни description — подписи лежат в `.accessibilityValue`,
// тем же приёмом, что и вкладки датасета.

import MarkdownUI
import SwiftUI

struct FineTuneChatDetailView: View {
    let dataset: FineTuneDataset
    @ObservedObject var viewModel: TuningChatViewModel
    @ObservedObject var server: MlxServerManager

    @State private var reportsSnapshot: TuningChatViewModel.BatchReportsSnapshot?

    var body: some View {
        Group {
            if dataset.workdir != "meetings" {
                ContentUnavailableView {
                    Label("Чат недоступен", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } description: {
                    Text("Чат доступен только для датасета «Встречи».")
                }
            } else {
                chatBody
            }
        }
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            messagesList
            Divider()
            inputArea
            Divider()
            batchSection
        }
        .task { reportsSnapshot = viewModel.batchReportsSnapshot() }
        .onChange(of: viewModel.lastBatchReportURL) { _, _ in
            reportsSnapshot = viewModel.batchReportsSnapshot()
        }
    }

    // MARK: - Статус сервера + переключатель варианта

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.caption).lineLimit(1)
            Spacer()
            variantButton(.baseline)
            variantButton(.tuned)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch server.status {
        case .stopped: return "Остановлен"
        case .starting(let text): return text
        case .running(let config): return "Работает: \(config.adapterPath != nil ? "тюн" : "baseline")"
        case .failed(let message): return "Ошибка: \(message)"
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .stopped: return .secondary
        case .starting: return .blue
        case .running: return .green
        case .failed: return .red
        }
    }

    private func variantButton(_ variant: FineTuneModelVariant) -> some View {
        let isActive = viewModel.modelVariant == variant
        let label = variant == .baseline ? "Базовая" : "Тюн"
        return Button {
            viewModel.modelVariant = variant
        } label: {
            Text(label)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isActive ? "\(label) — выбрано" : label)
        .disabled(viewModel.isGenerating)
        .help(label)
    }

    // MARK: - Сообщения

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            MessageBubble(message: chatMessage(for: message))
                            if let report = message.report {
                                ConfidenceVerdictChip(report: report)
                            }
                        }
                        .id(message.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                guard let last = viewModel.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func chatMessage(for message: TuningChatMessage) -> ChatMessage {
        ChatMessage(role: ChatRole(rawValue: message.role) ?? .assistant, content: message.content)
    }

    // MARK: - Ввод

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = viewModel.errorText {
                errorBanner(error)
            }
            if isVenvMissing {
                venvBanner
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Фрагмент транскрипта… (⌘⏎ — отправить)", text: $viewModel.input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...10)
                    .disabled(viewModel.isGenerating)
                if viewModel.isGenerating {
                    VStack(alignment: .trailing, spacing: 2) {
                        ProgressView().controlSize(.small)
                        if let progress = viewModel.progressText {
                            Text(progress).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    sendButton
                }
            }
        }
        .padding(10)
    }

    private var sendButton: some View {
        Button {
            Task { await viewModel.send() }
        } label: {
            Image(systemName: "paperplane.fill").font(.title3)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityValue("Отправить")
        .help("Отправить (⌘⏎)")
    }

    private var canSend: Bool {
        !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isGenerating
            && !isVenvMissing
    }

    // MARK: - Батч-прогон

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Батч-прогон").font(.caption.bold()).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                batchButton(.baseline)
                batchButton(.tuned)
                if let progress = viewModel.batchProgress {
                    Text("\(progress.current)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let error = viewModel.batchErrorText {
                errorBanner(error)
            }
            if let snapshot = reportsSnapshot {
                batchReportsView(snapshot)
            }
        }
        .padding(10)
    }

    private func batchButton(_ variant: FineTuneModelVariant) -> some View {
        let label = variant == .baseline ? "Батч: базовая" : "Батч: тюн"
        return Button {
            Task { await viewModel.runBatch(variant: variant) }
        } label: {
            Label(label, systemImage: "square.stack.3d.up")
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isGenerating || isVenvMissing)
        .accessibilityValue(label)
        .help("Прогнать 20 примеров valid.jsonl этим вариантом модели.")
    }

    @ViewBuilder
    private func batchReportsView(_ snapshot: TuningChatViewModel.BatchReportsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let baseline = snapshot.baselineURL {
                Text("baseline.md: \(baseline.path)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let tuned = snapshot.tunedURL {
                Text("tuned.md: \(tuned.path)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let summaryText = snapshot.summaryText {
                Markdown(summaryText).markdownTheme(.docC).textSelection(.enabled)
            } else if let summary = snapshot.summaryURL {
                Text("summary.md: \(summary.path)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: - Баннеры

    private func errorBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
    }

    private var isVenvMissing: Bool {
        if case .failed(let message) = server.status, message == FineTuneEnvironment.installHint { return true }
        return false
    }

    private var venvBanner: some View {
        Label {
            Text(Self.installHintText).font(.caption.monospaced())
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
    }

    /// Текст дословно из finetune/README.md — `mlx_lm.server` живёт в том же venv,
    /// что и остальной тулчейн.
    private static let installHintText = """
        mlx-lm не найден. Поставь его в отдельный venv (finetune/README.md):
            uv venv --python 3.11 finetune/.venv
            uv pip install --python finetune/.venv/bin/python -r finetune/requirements.txt
            finetune/.venv/bin/python finetune/providers.py   # проверка готовности
        """
}

/// Вердикт-чип под ответом ассистента: цветной бейдж OK/UNSURE/FAIL, раскрываемые
/// причины и метрики уверенности (вызовы, latency, токены).
private struct ConfidenceVerdictChip: View {
    let report: ConfidenceReport

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(report.reasons, id: \.self) { reason in
                    Text("• \(reason)").font(.caption)
                }
                Text(metricsLine).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } label: {
            Text(verdictLabel)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(verdictColor.opacity(0.18)))
                .foregroundStyle(verdictColor)
        }
        .accessibilityValue("вердикт: \(verdictLabel)")
    }

    private var verdictLabel: String {
        switch report.verdict {
        case .ok: return "OK"
        case .unsure: return "UNSURE"
        case .fail: return "FAIL"
        }
    }

    private var verdictColor: Color {
        switch report.verdict {
        case .ok: return .green
        case .unsure: return .yellow
        case .fail: return .red
        }
    }

    private var metricsLine: String {
        let m = report.metrics
        return "вызовов \(m.totalCalls) · latency осн. \(String(format: "%.1f", m.primaryLatency)) с / " +
            "полная \(String(format: "%.1f", m.totalLatency)) с · токены \(m.promptTokens)+\(m.completionTokens)"
    }
}
