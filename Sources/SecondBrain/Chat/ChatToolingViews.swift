// ChatToolingViews.swift — UI индикации туллинга в чате (задача 27):
// чипы источников инструментов над полем ввода и карточка-мастер
// «Ассистент проекта» в пустом чате.
//
// Поповеры якорятся к самим чипам (они живут в inputBar) — НЕ к тулбару:
// ToolbarItem пересоздаётся при обновлениях и убивает поповер (урок панели
// синка, задача 24). Модели чипов/шагов — чистые структуры ToolingStatus.swift.

import SwiftUI

// MARK: - Чипы источников инструментов

/// Ряд чипов включённых источников инструментов текущего чата.
struct ToolChipsRow: View {
    let summaries: [ToolSourceSummary]
    /// Выключить источник для этого чата (чип показывается только включённым).
    let onDisable: (ToolSourceSummary) -> Void
    /// Открыть настройки на вкладке «Инструменты».
    let onConfigure: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(summaries) { summary in
                    ToolSourceChip(summary: summary,
                                   onDisable: { onDisable(summary) },
                                   onConfigure: onConfigure)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// Один чип: светофор состояния + название + число инструментов; клик —
/// поповер со статусом и действиями.
private struct ToolSourceChip: View {
    let summary: ToolSourceSummary
    let onDisable: () -> Void
    let onConfigure: () -> Void

    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                Image(systemName: iconName)
                    .font(.caption2)
                Text(chipTitle)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(summary.detail)
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.title)
                    .font(.headline)
                Text(summary.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Button("Выключить для этого чата") {
                    showsPopover = false
                    onDisable()
                }
                Button("Настроить…") {
                    showsPopover = false
                    onConfigure()
                }
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
        }
    }

    private var chipTitle: String {
        summary.count.map { "\(summary.title) · \($0)" } ?? summary.title
    }

    private var iconName: String {
        switch summary.kind {
        case .project: return "hammer"
        case .mcp: return "wrench.and.screwdriver"
        }
    }

    private var stateColor: Color {
        switch summary.state {
        case .ok: return .green
        case .unknown: return .gray
        case .warning: return .orange
        }
    }
}

// MARK: - Чип базы знаний (RAG)

/// Чип «База» (задачи 28, 31): выбранный источник знаний и его состояние
/// видны без единого клика; поповер — переключатель источника (vault/проект)
/// и действие (индексировать/переиндексировать/открыть настройки).
struct RagStatusChip: View {
    let summary: RagChipSummary
    /// Запустить индексацию vault (true — полная переиндексация).
    let onReindex: (Bool) -> Void
    let onOpenSettings: (SettingsTab) -> Void
    /// Смена источника знаний чата (задача 31).
    let onSelectSource: (KnowledgeSource) -> Void

    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                if case .indexing(let fraction) = summary.state {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)
                }
                Image(systemName: "books.vertical")
                    .font(.caption2)
                Text(summary.title)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(summary.detail)
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("База знаний (RAG)")
                    .font(.headline)
                // Единая точка выбора источника (задача 31): по чему отвечает
                // этот чат — заметки vault или документация репозитория.
                Picker("Источник", selection: Binding(
                    get: { summary.source },
                    set: { onSelectSource($0) }
                )) {
                    Text("Vault (заметки)").tag(KnowledgeSource.vault)
                    Text("Проект (репозиторий)").tag(KnowledgeSource.project)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(summary.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                popoverActions
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
        }
    }

    @ViewBuilder
    private var popoverActions: some View {
        switch summary.state {
        case .ready:
            Button("Настройки индекса…") {
                showsPopover = false
                onOpenSettings(summary.source == .vault ? .general : .tools)
            }
        case .indexing:
            Text("Индексация идёт — можно продолжать работу.")
                .font(.caption)
        case .noEmbedder:
            Button("Открыть настройки") {
                showsPopover = false
                onOpenSettings(.localModels)
            }
        case .empty:
            if summary.source == .vault {
                Button("Индексировать") {
                    showsPopover = false
                    onReindex(false)
                }
            } else {
                Text("Задайте вопрос — индекс построится автоматически.")
                    .font(.caption)
            }
        case .needsReindex:
            Button("Переиндексировать заново") {
                showsPopover = false
                onReindex(true)
            }
        case .repoMissing:
            Button("Выбрать репозиторий…") {
                showsPopover = false
                onOpenSettings(.tools)
            }
        }
    }

    private var stateColor: Color {
        switch summary.health {
        case .ok: return .green
        case .unknown: return .gray
        case .warning: return .orange
        }
    }
}

// MARK: - Мастер «Ассистент проекта»

/// Карточка в пустом чате: три шага до работающего ассистента проекта.
/// Исчезает с первым сообщением (living в empty-state ленты).
struct ProjectWizardCard: View {
    let state: ProjectWizardState
    let onPickRepo: () -> Void
    let onOpenSettings: (SettingsTab) -> Void
    let onEnableTools: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ассистент проекта — 3 шага")
                .font(.headline)
            ForEach(state.steps) { step in
                HStack(spacing: 8) {
                    Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(step.done ? Color.green : Color.secondary)
                    Text(step.title)
                        .font(.callout)
                    Spacer()
                    if !step.done { stepActions(step) }
                }
            }
            Text("Дальше: `/help как устроен проект?` — ответ по документации и git выбранного репозитория.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder
    private func stepActions(_ step: ProjectWizardState.Step) -> some View {
        switch step.kind {
        case .repo:
            Button("Выбрать…") { onPickRepo() }
                .help("Выбрать папку git-репозитория проекта")
            Button("Настройки…") { onOpenSettings(.tools) }
                .help("Открыть вкладку «Инструменты»")
        case .model:
            Button("Открыть настройки…") { onOpenSettings(.providers) }
                .help("Ключи облачных провайдеров — вкладка «Провайдеры»; локальные — «Локальные модели»")
        case .tools:
            Button("Включить") { onEnableTools() }
                .disabled(!state.repoDone)
                .help(state.repoDone ? "Включить git-инструменты в этом чате"
                                     : "Сначала выберите репозиторий")
        }
    }
}
