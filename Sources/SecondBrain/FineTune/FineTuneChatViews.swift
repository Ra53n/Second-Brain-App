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
    @ObservedObject var registry: ProviderRegistry

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
            sessionStatsSection
            Divider()
            pipelineConfigRow
            if viewModel.escalationEnabled {
                escalationTargetRow
            }
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
            basePicker
            variantButton(.baseline)
            variantButton(.tuned)
            Button {
                viewModel.clearChat()
            } label: {
                Label("Очистить чат", systemImage: "trash")
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityValue("Очистить чат")
            .help("Удалить историю текущего треда (Базовая/Тюн), обнулить статистику сессии и отменить текущую генерацию или батч")
            .disabled(viewModel.messages.isEmpty && !viewModel.isGenerating)
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

    private func variantLabel(_ variant: FineTuneModelVariant) -> String {
        variant == .baseline ? "Базовая" : "Тюн"
    }

    /// Пикер базы чата (задача 92): baseline↔тюн сравниваются на одной базе, смена
    /// базы — рестарт mlx-сервера (см. `.help`), поэтому заблокирован во время генерации.
    private var basePicker: some View {
        Picker("База", selection: chatBaseModelBinding) {
            ForEach(viewModel.availableBaseModels, id: \.self) { model in
                Text(TuneSelection.adapterDirName(model: model)).tag(model)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 170)
        .disabled(viewModel.isGenerating)
        .accessibilityValue(TuneSelection.adapterDirName(model: viewModel.chatBaseModel))
        .help("Смена базы перезапускает mlx-сервер — загрузка модели может занять до минуты.")
    }

    private var chatBaseModelBinding: Binding<String> {
        Binding(get: { viewModel.chatBaseModel }, set: { viewModel.setChatBaseModel($0) })
    }

    private func variantButton(_ variant: FineTuneModelVariant) -> some View {
        let isActive = viewModel.modelVariant == variant
        let label = variantLabel(variant)
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
                            if let escalation = message.escalation {
                                EscalationBadge(record: escalation, shownVerdict: message.report?.verdict)
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

    // MARK: - Статистика сессии

    private var sessionStatsSection: some View {
        let stats = viewModel.sessionStats // один вызов на проход body (computed по сообщениям)
        let lastReport = viewModel.lastReport
        return VStack(alignment: .leading, spacing: 6) {
            Text("Статистика — \(variantLabel(viewModel.modelVariant))").font(.caption.bold())
            if let stats {
                if let last = lastReport {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                        GridRow {
                            Text("Последний запрос").foregroundStyle(.secondary).gridColumnAlignment(.leading)
                            HStack(spacing: 6) {
                                statChip(last.verdict.uiLabel, color: last.verdict.uiColor)
                                Text(String(format: "вызовов %d (доп. %d) · ответ %.1f с / всего %.1f с · %@ + %@ ток.",
                                            last.metrics.totalCalls, last.metrics.extraCalls,
                                            last.metrics.primaryLatency, last.metrics.totalLatency,
                                            formattedTokens(last.metrics.promptTokens),
                                            formattedTokens(last.metrics.completionTokens)))
                            }
                        }
                        if let escalation = viewModel.lastEscalation {
                            GridRow {
                                Text("")
                                Text(lastEscalationLine(escalation, shownVerdict: last.verdict))
                                    .foregroundStyle(escalation.status == .succeeded ? .purple : .orange)
                            }
                        }
                    }
                    .font(.caption)
                    Divider()
                }
                HStack(spacing: 6) {
                    Text("Сессия").font(.caption).foregroundStyle(.secondary)
                    statChip("Ответов: \(stats.answered)", color: .secondary)
                    statChip("OK: \(stats.ok)", color: .green)
                    statChip("UNSURE: \(stats.unsure)", color: .yellow)
                    statChip("FAIL: \(stats.rejected)", color: .red)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Повторный инференс").foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text("\(stats.needingReinference) из \(stats.answered) ответов · доп. вызовов: \(stats.extraCallsTotal)")
                    }
                    GridRow {
                        Text("Latency").foregroundStyle(.secondary)
                        Text(String(format: "ответ %.1f с → с пайплайном %.1f с (наценка ×%.2f)",
                                    stats.avgPrimaryLatency, stats.avgTotalLatency, stats.latencyFactor))
                    }
                    if let withExtra = stats.avgLatencyWithExtraCalls,
                       let withoutExtra = stats.avgLatencyWithoutExtraCalls {
                        GridRow {
                            Text("")
                            Text(String(format: "ответы с доп. вызовами %.1f с · без них %.1f с",
                                        withExtra, withoutExtra))
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Токены (cost)").foregroundStyle(.secondary)
                        Text("\(formattedTokens(stats.promptTokens)) запрос + \(formattedTokens(stats.completionTokens)) ответ")
                    }
                    if stats.escalatedCount + stats.escalationFailedCount > 0 {
                        GridRow {
                            Text("Эскалация").foregroundStyle(.secondary)
                            Text(String(format: "%d из %d (%.0f%%) · неудач %d · +%.1f с · +%@ ток.",
                                        stats.escalatedCount, stats.answered, stats.escalationShare * 100,
                                        stats.escalationFailedCount, stats.escalationAddedLatency,
                                        formattedTokens(stats.escalationPromptTokens + stats.escalationCompletionTokens)))
                        }
                    }
                }
                .font(.caption)
            } else {
                Text("Пока нет ответов — отправьте фрагмент, счётчики появятся здесь.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Голый VStack не гарантированно всплывает в AX-дерево — схлопываем в один
        // элемент, чтобы value доходил до System Events (замечание ревью задачи 88).
        .accessibilityElement(children: .combine)
        .accessibilityValue(stats.map {
            sessionStatsAccessibilityValue($0, lastReport: lastReport, lastEscalation: viewModel.lastEscalation,
                                            variant: viewModel.modelVariant)
        } ?? "статистика (\(variantLabel(viewModel.modelVariant))): пока нет ответов")
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func statChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private func formattedTokens(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "ru_RU")))
    }

    /// Строка эскалации последнего ответа для блока «Последний запрос»: успех —
    /// оба вердикта (триггер дешёвой → итог показанного), неудача — причина.
    private func lastEscalationLine(_ escalation: EscalationRecord, shownVerdict: ConfidenceVerdict) -> String {
        switch escalation.status {
        case .succeeded:
            return "эскалация: \(escalation.providerID ?? "?")/\(escalation.model ?? "?"), " +
                "\(escalation.trigger.uiLabel) → \(shownVerdict.uiLabel)"
        case .failed:
            return "эскалация не удалась: \(escalation.failureReason ?? "причина неизвестна")"
        case .unavailable:
            return "эскалация недоступна: \(escalation.failureReason ?? "причина неизвестна")"
        }
    }

    private func sessionStatsAccessibilityValue(_ stats: TuningChatSessionStats,
                                                 lastReport: ConfidenceReport?,
                                                 lastEscalation: EscalationRecord?,
                                                 variant: FineTuneModelVariant) -> String {
        let last = lastReport.map {
            "последний запрос: \($0.verdict.uiLabel), вызовов \($0.metrics.totalCalls); "
        } ?? ""
        let escalationLast: String
        if let lastReport, let lastEscalation {
            escalationLast = "\(lastEscalationLine(lastEscalation, shownVerdict: lastReport.verdict)); "
        } else {
            escalationLast = ""
        }
        let escalationSession = (stats.escalatedCount + stats.escalationFailedCount) > 0
            ? "эскалаций \(stats.escalatedCount), неудач \(stats.escalationFailedCount); "
            : ""
        return "статистика (\(variantLabel(variant))): \(last)\(escalationLast)\(escalationSession)" +
        "сессия: отвечено \(stats.answered), отклонено \(stats.rejected), " +
        "повторный инференс \(stats.needingReinference), доп. вызовов \(stats.extraCallsTotal), " +
        "наценка latency ×\(String(format: "%.2f", stats.latencyFactor))"
    }

    // MARK: - Регулировка пайплайна

    private var pipelineConfigRow: some View {
        HStack(spacing: 8) {
            pipelineChip("Проверки", isOn: viewModel.pipelineConfig.constraintEnabled) { on in
                var config = viewModel.pipelineConfig
                config.constraintEnabled = on
                viewModel.setPipelineConfig(config)
            }
            pipelineChip("Повторы ×3", isOn: viewModel.pipelineConfig.redundancyEnabled) { on in
                var config = viewModel.pipelineConfig
                config.redundancyEnabled = on
                viewModel.setPipelineConfig(config)
            }
            pipelineChip("Скоринг", isOn: viewModel.pipelineConfig.scoringEnabled) { on in
                var config = viewModel.pipelineConfig
                config.scoringEnabled = on
                viewModel.setPipelineConfig(config)
            }
            pipelineChip("Self-check", isOn: viewModel.pipelineConfig.selfCheckEnabled) { on in
                var config = viewModel.pipelineConfig
                config.selfCheckEnabled = on
                viewModel.setPipelineConfig(config)
            }
            pipelineChip("Эскалация", isOn: viewModel.escalationEnabled) { on in
                viewModel.setEscalationEnabled(on)
            }
            .help("UNSURE/FAIL дешёвой модели повторяется на выбранной сильной; при всех выключенных проверках вердикт всегда UNSURE — эскалация сработает на каждом сообщении")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Цель эскалации

    /// Tag-тип пикера цели эскалации (задача 93): `.registry` — провайдер
    /// `ProviderRegistry` (как раньше), `.localTuned` — база локального тюна из
    /// `viewModel.availableTunedModels` (ядро 92, реестр/стор во View не тянутся).
    private enum EscalationPickerChoice: Hashable {
        case none
        case registry(ProviderID)
        case localTuned(String)
    }

    private var escalationTargetRow: some View {
        HStack(spacing: 8) {
            Picker("Сильная модель", selection: escalationChoiceBinding) {
                Text("Не выбрано").tag(EscalationPickerChoice.none)
                ForEach(registry.descriptors(supporting: .chat)) { descriptor in
                    Text(descriptor.displayName).tag(EscalationPickerChoice.registry(descriptor.id))
                }
                if !viewModel.availableTunedModels.isEmpty {
                    Section("Локально (mlx)") {
                        ForEach(viewModel.availableTunedModels, id: \.self) { model in
                            Text(Self.localTunedLabel(model))
                                .tag(EscalationPickerChoice.localTuned(model))
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityValue(escalationChoiceAccessibilityValue)
            if viewModel.escalationTarget?.kind != .localTuned {
                TextField("модель", text: escalationModelBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .disabled(viewModel.escalationTarget == nil)
            }
            Spacer()
        }
        .disabled(viewModel.isGenerating)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private static func localTunedLabel(_ model: String) -> String {
        TuneSelection.localTunedDisplayName(model: model)
    }

    private var escalationChoiceBinding: Binding<EscalationPickerChoice> {
        Binding(
            get: {
                guard let target = viewModel.escalationTarget else { return .none }
                switch target.kind {
                case .registry: return .registry(target.providerID)
                case .localTuned: return .localTuned(target.model)
                }
            },
            set: { choice in
                switch choice {
                case .none:
                    viewModel.setEscalationTarget(nil)
                case let .registry(providerID):
                    let model = registry.preferredDefaultModel(for: providerID, capability: .chat) ?? ""
                    viewModel.setEscalationTarget(EscalationTarget(providerID: providerID, model: model, kind: .registry))
                case let .localTuned(model):
                    viewModel.setEscalationTarget(
                        EscalationTarget(providerID: .localTunedProviderID, model: model, kind: .localTuned))
                }
            }
        )
    }

    private var escalationModelBinding: Binding<String> {
        Binding(
            get: { viewModel.escalationTarget?.model ?? "" },
            set: { newModel in
                guard let providerID = viewModel.escalationTarget?.providerID else { return }
                viewModel.setEscalationTarget(EscalationTarget(providerID: providerID, model: newModel))
            }
        )
    }

    private var escalationChoiceAccessibilityValue: String {
        guard let target = viewModel.escalationTarget else { return "Не выбрано" }
        switch target.kind {
        case .registry:
            return registry.descriptor(for: target.providerID)?.displayName ?? "Не выбрано"
        case .localTuned:
            return Self.localTunedLabel(target.model)
        }
    }

    private func pipelineChip(_ label: String, isOn: Bool, toggle: @escaping (Bool) -> Void) -> some View {
        Button {
            toggle(!isOn)
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isOn ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "\(label) — включено" : "\(label) — выключено")
        .disabled(viewModel.isGenerating)
        .help("Действует на следующее сообщение")
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
            Text("Батч всегда гонит полный пайплайн — тумблеры выше на него не влияют.")
                .font(.caption2).foregroundStyle(.secondary)
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
            HStack(spacing: 6) {
                Text(verdictLabel)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(verdictColor.opacity(0.18)))
                    .foregroundStyle(verdictColor)
                // Первая причина видна без раскрытия — «FAIL» без объяснения ставит
                // пользователя в тупик (фидбэк задачи 87).
                if report.verdict != .ok, let reason = report.reasons.first {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityValue("вердикт: \(verdictLabel)")
    }

    private var verdictLabel: String { report.verdict.uiLabel }

    private var verdictColor: Color { report.verdict.uiColor }

    private var metricsLine: String {
        let m = report.metrics
        return "вызовов \(m.totalCalls) · latency осн. \(String(format: "%.1f", m.primaryLatency)) с / " +
            "полная \(String(format: "%.1f", m.totalLatency)) с · токены \(m.promptTokens)+\(m.completionTokens)"
    }
}

/// Бейдж эскалации под сообщением (задача 91): успех — фиолетовая капсула с целью
/// эскалации + оба вердикта; неудача/недоступность — оранжевая капсула с причиной.
private struct EscalationBadge: View {
    let record: EscalationRecord
    let shownVerdict: ConfidenceVerdict?

    var body: some View {
        HStack(spacing: 6) {
            Text(capsuleLabel)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.18)))
                .foregroundStyle(color)
            Text(detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("эскалация: \(capsuleLabel) — \(detailText)")
    }

    private var color: Color { record.status == .succeeded ? .purple : .orange }

    private var capsuleLabel: String {
        switch record.status {
        case .succeeded: return "⤴ \(record.providerID ?? "?")/\(record.model ?? "?")"
        case .failed: return "эскалация не удалась"
        // Недоступность — эскалация не запускалась вовсе, «не удалась» вводила бы в заблуждение.
        case .unavailable: return "эскалация недоступна"
        }
    }

    private var detailText: String {
        switch record.status {
        case .succeeded:
            return "\(record.trigger.uiLabel) → \(shownVerdict?.uiLabel ?? "?")"
        case .failed, .unavailable:
            return record.failureReason ?? "причина неизвестна"
        }
    }
}

// Единый маппинг вердикта в подпись и цвет — используется и чипом сообщения,
// и блоком «Последний запрос» (ревью задачи 90: третья копия недопустима).
extension ConfidenceVerdict {
    var uiLabel: String {
        switch self {
        case .ok: return "OK"
        case .unsure: return "UNSURE"
        case .fail: return "FAIL"
        }
    }

    var uiColor: Color {
        switch self {
        case .ok: return .green
        case .unsure: return .yellow
        case .fail: return .red
        }
    }
}
