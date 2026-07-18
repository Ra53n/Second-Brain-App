// ChatToolingViews.swift — UI индикации туллинга в чате (задача 27):
// чипы источников инструментов над полем ввода и карточка-мастер
// «Ассистент проекта» в пустом чате.
//
// Поповеры якорятся к самим чипам (они живут в inputBar) — НЕ к тулбару:
// ToolbarItem пересоздаётся при обновлениях и убивает поповер (урок панели
// синка, задача 24). Модели чипов/шагов — чистые структуры ToolingStatus.swift.

import SwiftUI

// MARK: - Чипы источников инструментов

/// Контролы чипа «Проект» (задача 39): per-chat каталог, режим разрешений,
/// «Сделать базой знаний». Чистая модель для поповера — колбэки в ChatView.
struct ProjectChipControls {
    /// Эффективный путь (override чата либо глобальный); nil — не задан.
    var effectivePath: String?
    /// Каталог переопределён для этого чата.
    var isOverride: Bool
    var mode: AgentPermissionMode
    var onPickChatRoot: () -> Void
    var onResetChatRoot: () -> Void
    var onSetMode: (AgentPermissionMode) -> Void
    var onMakeKnowledgeBase: () -> Void
}

/// Ряд чипов включённых источников инструментов текущего чата.
struct ToolChipsRow: View {
    let summaries: [ToolSourceSummary]
    /// Выключить источник для этого чата (чип показывается только включённым).
    let onDisable: (ToolSourceSummary) -> Void
    /// Открыть настройки на вкладке «Инструменты».
    let onConfigure: () -> Void
    /// Контролы чипа «Проект» (задача 39); nil — секция не рисуется.
    var projectControls: ProjectChipControls?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(summaries) { summary in
                    ToolSourceChip(summary: summary,
                                   onDisable: { onDisable(summary) },
                                   onConfigure: onConfigure,
                                   projectControls: summary.kind == .project
                                       ? projectControls : nil)
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
    var projectControls: ProjectChipControls?

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
                if let controls = projectControls {
                    projectSection(controls)
                }
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
            .frame(width: 320, alignment: .leading)
        }
    }

    /// Секция чипа «Проект» (задача 39): каталог этого чата, режим
    /// разрешений и создание базы знаний из каталога.
    @ViewBuilder
    private func projectSection(_ controls: ProjectChipControls) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Text("Каталог: \(controls.effectivePath ?? "не выбран")"
                 + (controls.isOverride ? " (этого чата)" : " (глобальный)"))
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Button("Выбрать для чата…") {
                    showsPopover = false
                    controls.onPickChatRoot()
                }
                .help("Любой репозиторий, папка или vault — только для этого чата")
                if controls.isOverride {
                    Button("Вернуть глобальный") { controls.onResetChatRoot() }
                }
            }
            .controlSize(.small)
            Picker("Режим", selection: Binding(
                get: { controls.mode },
                set: { controls.onSetMode($0) }
            )) {
                ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help(controls.mode.help)
            if controls.mode == .autoDanger {
                Label("Все операции — без подтверждений, включая удаление и команды.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button("Сделать базой знаний") {
                showsPopover = false
                controls.onMakeKnowledgeBase()
            }
            .controlSize(.small)
            .disabled(controls.effectivePath == nil)
            .help("Добавить каталог в реестр баз знаний и включить rag_search по нему в этом чате (индекс .md построится при первом поиске)")
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

/// Чип «База» (задачи 28, 31, 34): включённые базы знаний и их состояние
/// видны без единого клика; поповер — мультивыбор баз реестра (чекбокс на
/// базу) с per-base действием (индексировать/переиндексировать/настройки).
struct RagStatusChip: View {
    let summary: RagChipSummary
    /// Запустить индексацию vault (true — полная переиндексация).
    let onReindex: (Bool) -> Void
    let onOpenSettings: (SettingsTab) -> Void
    /// Переключить базу для этого чата (задача 34, мультивыбор).
    let onToggleBase: (String) -> Void

    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                if summary.isIndexing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(color(summary.health))
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
                Text("Базы знаний (RAG)")
                    .font(.headline)
                Text("Модель ищет только во включённых базах этого чата.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(summary.rows) { row in
                    baseRow(row)
                }
                Divider()
                Button("Управлять базами…") {
                    showsPopover = false
                    onOpenSettings(.tools)
                }
                .help("Добавить папки заметок и настроить базы — вкладка «Инструменты»")
            }
            .padding(12)
            .frame(width: 340, alignment: .leading)
        }
    }

    /// Строка базы: чекбокс per-чат + светофор + имя/статус + действие.
    @ViewBuilder
    private func baseRow(_ row: KnowledgeBaseChipRow) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { row.enabledInChat },
                set: { _ in onToggleBase(row.baseID) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            if case .indexing(let fraction) = row.state {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(color(row.health))
                    .frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle(row))
                    .font(.callout)
                Text(row.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            rowAction(row)
        }
    }

    private func rowTitle(_ row: KnowledgeBaseChipRow) -> String {
        if case .ready(let chunks) = row.state { return "\(row.name) · \(chunks)" }
        return row.name
    }

    /// Действие строки по состоянию: vault индексируется кнопкой, остальные —
    /// лениво; сломанные пути и отсутствие эмбеддера ведут в настройки.
    @ViewBuilder
    private func rowAction(_ row: KnowledgeBaseChipRow) -> some View {
        switch row.state {
        case .empty where row.baseID == KnowledgeBase.vaultID:
            Button("Индексировать") {
                showsPopover = false
                onReindex(false)
            }
            .controlSize(.small)
        case .needsReindex:
            Button("Заново") {
                showsPopover = false
                onReindex(true)
            }
            .controlSize(.small)
            .help("Полная переиндексация под новую модель эмбеддинга")
        case .noEmbedder:
            Button("Настроить…") {
                showsPopover = false
                onOpenSettings(.localModels)
            }
            .controlSize(.small)
        case .pathMissing:
            Button("Выбрать…") {
                showsPopover = false
                onOpenSettings(.tools)
            }
            .controlSize(.small)
        case .ready, .indexing, .empty:
            EmptyView()
        }
    }

    private func color(_ health: ToolSourceSummary.Health) -> Color {
        switch health {
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
