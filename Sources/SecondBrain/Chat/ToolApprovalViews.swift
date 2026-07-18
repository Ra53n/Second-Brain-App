// ToolApprovalViews.swift — UI слоя разрешений (задача 39).
//
// Карточка ожидающих подтверждения операций над полем ввода (пока она
// видна — tool-цикл ждёт решения на continuation в ToolApprovalCenter) и
// переиспользуемые блоки: раскрашенный unified diff и свёрнутый список
// применённых изменений файлов в MessageBubble.

import SwiftUI

// MARK: - Раскрашенный diff

/// Построчный рендер unified diff: + зелёным, − красным, @@ синим,
/// моноширинный шрифт. Текст выделяемый (скопировать diff можно).
struct DiffTextView: View {
    let diff: String

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.components(separatedBy: "\n").enumerated()),
                        id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(color(for: line))
                        .textSelection(.enabled)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }
}

// MARK: - Карточка подтверждения операции

/// Запросы разрешений текущего чата: операция, уровень риска, детали
/// (diff/команда/аргументы) и решение — один раз / на сессию / отклонить.
struct ToolApprovalCard: View {
    let approvals: [PendingToolApproval]
    let onDecision: (UUID, ToolApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Агент запрашивает разрешение", systemImage: "hand.raised")
                .font(.caption.bold())
            ForEach(approvals) { approval in
                approvalRow(approval)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Color.orange.opacity(0.35)))
    }

    @ViewBuilder
    private func approvalRow(_ approval: PendingToolApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(approval.toolName)
                    .font(.caption.bold().monospaced())
                Text(approval.risk.label)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(riskColor(approval.risk).opacity(0.15)))
                    .foregroundStyle(riskColor(approval.risk))
                Spacer()
            }
            if !approval.detail.isEmpty {
                DisclosureGroup {
                    DiffTextView(diff: approval.detail)
                        .frame(maxHeight: 260)
                } label: {
                    Text(detailSummary(approval.detail))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                Button("Разрешить") { onDecision(approval.id, .allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .help("Выполнить эту операцию один раз")
                Button("На сессию") { onDecision(approval.id, .allowSession) }
                    .help("Разрешить такие операции до перезапуска приложения")
                Button("Отклонить") { onDecision(approval.id, .deny) }
                    .help("Не выполнять; модель получит отказ и продолжит без операции")
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.06)))
    }

    /// Первая содержательная строка деталей — подпись DisclosureGroup.
    private func detailSummary(_ detail: String) -> String {
        detail.components(separatedBy: "\n").first ?? detail
    }

    private func riskColor(_ risk: ToolRiskLevel) -> Color {
        switch risk {
        case .safe: return .green
        case .write: return .orange
        case .dangerous: return .red
        }
    }
}

// MARK: - Изменения файлов в сообщении

/// Свёрнутый блок применённых файловых операций хода (паттерн блока
/// «Инструменты»): путь + вид операции + раскрашенный diff.
struct FileChangesBlock: View {
    let changes: [FileChangeDisplay]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(changes) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: icon(change.kind))
                                .font(.caption2)
                            Text(change.relativePath)
                                .font(.caption.bold().monospaced())
                            Text(change.kind.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        DiffTextView(diff: change.diff)
                            .frame(maxHeight: 200)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.08)))
                }
            }
        } label: {
            Label("Изменения файлов (\(changes.count))", systemImage: "doc.badge.gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func icon(_ kind: FileChangeDisplay.Kind) -> String {
        switch kind {
        case .created: return "doc.badge.plus"
        case .modified: return "pencil"
        case .deleted: return "trash"
        }
    }
}
