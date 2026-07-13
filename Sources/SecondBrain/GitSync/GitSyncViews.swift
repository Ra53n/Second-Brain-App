// GitSyncViews.swift — UI git-синхронизации (задача 16).
//
// Здесь живут:
//  - SyncStatusButton — индикатор состояния в тулбаре (чисто/изменения/
//    ahead/behind/ошибка), клик открывает панель;
//  - GitSyncPanel    — панель: изменённые файлы, Commit+Push / Pull,
//    история, авто-бэкап, включение синка, починка remote, .gitignore;
//  - диалог конфликтов pull («принять свои / удалённые / открыть в Finder»).
//
// View только читают SyncViewModel и зовут его методы — вся логика там.

import SwiftUI

/// Кнопка-индикатор синка для тулбара. Иконка отражает состояние, клик —
/// popover с полной панелью.
struct SyncStatusButton: View {
    @ObservedObject var viewModel: SyncViewModel
    @State private var showsPanel = false

    var body: some View {
        Button {
            showsPanel.toggle()
        } label: {
            Label("Синхронизация", systemImage: iconName)
                .foregroundStyle(iconColor)
        }
        .help(helpText)
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            GitSyncPanel(viewModel: viewModel)
        }
        // Обновляем статус при каждом открытии панели: дёшево и всегда свежо.
        .onChange(of: showsPanel) { _, shown in
            if shown { Task { await viewModel.refresh() } }
        }
    }

    private var iconName: String {
        if viewModel.isBusy { return "arrow.triangle.2.circlepath" }
        switch viewModel.repoState {
        case .noVault, .checking: return "icloud.slash"
        case .gitUnavailable: return "exclamationmark.icloud"
        case .notARepo: return "icloud.slash"
        case .ready:
            if viewModel.lastError != nil || viewModel.conflictFiles != nil {
                return "exclamationmark.icloud"
            }
            guard let status = viewModel.status else { return "checkmark.icloud" }
            if !status.isClean { return "pencil.circle" }
            if status.ahead > 0 { return "icloud.and.arrow.up" }
            if status.behind > 0 { return "icloud.and.arrow.down" }
            return "checkmark.icloud"
        }
    }

    private var iconColor: Color {
        if case .ready = viewModel.repoState {
            if viewModel.lastError != nil || viewModel.conflictFiles != nil { return .orange }
            if viewModel.status?.isClean == false { return .accentColor }
            return .secondary
        }
        return .secondary
    }

    private var helpText: String {
        switch viewModel.repoState {
        case .noVault: return "Vault не открыт"
        case .checking: return "Проверяем состояние git…"
        case .gitUnavailable: return "git недоступен"
        case .notARepo: return "Синхронизация не включена"
        case .ready:
            guard let status = viewModel.status else { return "Git-синхронизация" }
            var parts: [String] = []
            if !status.changes.isEmpty { parts.append("изменений: \(status.changes.count)") }
            if status.ahead > 0 { parts.append("↑\(status.ahead)") }
            if status.behind > 0 { parts.append("↓\(status.behind)") }
            return parts.isEmpty ? "Синхронизировано" : parts.joined(separator: ", ")
        }
    }
}

/// Панель синхронизации: содержимое зависит от repoState.
struct GitSyncPanel: View {
    @ObservedObject var viewModel: SyncViewModel
    /// Черновик URL remote для «Включить синхронизацию».
    @State private var remoteDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch viewModel.repoState {
            case .noVault:
                Text("Откройте vault, чтобы настроить синхронизацию.")
                    .foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
            case .gitUnavailable(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .notARepo:
                enableSection
            case .ready:
                readySection
            }
        }
        .padding(14)
        .frame(width: 400)
        // Конфликт pull: merge уже прерван, файлы целы — выбор стратегии.
        .confirmationDialog(
            "Конфликт при слиянии",
            isPresented: Binding(
                get: { viewModel.conflictFiles != nil },
                set: { if !$0 { viewModel.conflictFiles = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Принять свои версии") { viewModel.resolveConflicts(preferring: .ours) }
            Button("Принять удалённые версии") { viewModel.resolveConflicts(preferring: .theirs) }
            Button("Открыть в Finder") {
                viewModel.revealInFinder(paths: viewModel.conflictFiles ?? [])
                viewModel.conflictFiles = nil
            }
            Button("Отмена", role: .cancel) { viewModel.conflictFiles = nil }
        } message: {
            Text("Merge прерван, файлы не тронуты. Конфликтуют:\n"
                 + (viewModel.conflictFiles ?? []).joined(separator: "\n"))
        }
    }

    // MARK: - Секции

    private var header: some View {
        HStack {
            Text("Git-синхронизация")
                .font(.headline)
            Spacer()
            if viewModel.isBusy {
                ProgressView().controlSize(.small)
                if let label = viewModel.busyLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Vault без git: init + опциональный remote.
    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vault не под git. Включите синхронизацию — история изменений и бэкап на другие Mac.")
                .foregroundStyle(.secondary)
            TextField("URL remote (необязательно)", text: $remoteDraft)
                .textFieldStyle(.roundedBorder)
            Text("Например git@github.com:user/vault.git — auth через SSH или системный Keychain; токены в URL не поддерживаются намеренно.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Включить синхронизацию") {
                viewModel.enableSync(remoteURL: remoteDraft)
            }
            .disabled(viewModel.isBusy)
            errorBanner
        }
    }

    @ViewBuilder
    private var readySection: some View {
        branchLine
        credentialWarningBanner
        errorBanner
        changesSection
        actionButtons
        autoBackupSection
        gitignoreSection
        historySection
    }

    private var branchLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            Text(viewModel.status?.branch ?? "—")
                .font(.body.monospaced())
            if let upstream = viewModel.status?.upstream {
                Text("→ \(upstream)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let status = viewModel.status, status.ahead > 0 || status.behind > 0 {
                Text("↑\(status.ahead) ↓\(status.behind)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Анти-паттерн «токен в URL remote»: показать секрет и предложить убрать.
    @ViewBuilder
    private var credentialWarningBanner: some View {
        if let warning = viewModel.credentialWarning {
            VStack(alignment: .leading, spacing: 6) {
                Label("В URL remote «\(warning.remoteName)» зашит токен — это небезопасно.",
                      systemImage: "key.slash")
                    .foregroundStyle(.orange)
                Text("Сохраните токен (ниже) в менеджере паролей, затем уберите его из URL. Git продолжит работать через системный Keychain или SSH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(warning.credential)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                Button("Убрать токен из URL") { viewModel.fixRemoteCredential() }
                    .disabled(viewModel.isBusy)
            }
            .padding(8)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.lastError {
            HStack(alignment: .top) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    viewModel.lastError = nil
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var changesSection: some View {
        if let status = viewModel.status {
            if status.changes.isEmpty {
                Label("Изменений нет", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Изменения (\(status.changes.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(status.changes) { change in
                                HStack {
                                    Text(change.path)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(change.kind.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Сообщение коммита (пусто — «vault backup: …»)",
                      text: $viewModel.commitMessageDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Commit + Push") { viewModel.commitAndPush() }
                    .disabled(viewModel.isBusy || commitDisabled)
                Button("Pull") { viewModel.pull() }
                    .disabled(viewModel.isBusy || viewModel.remotes.isEmpty)
                Spacer()
                Button {
                    Task { await viewModel.refresh(fetching: true) }
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isBusy)
                .help("git fetch + статус: актуальные ahead/behind")
            }
        }
    }

    /// Нечего ни коммитить, ни допушивать.
    private var commitDisabled: Bool {
        guard let status = viewModel.status else { return true }
        return status.isClean && status.ahead == 0
    }

    private var autoBackupSection: some View {
        HStack {
            Picker("Авто-бэкап", selection: $viewModel.autoBackupMinutes) {
                ForEach(SyncViewModel.autoBackupChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? "выключен" : "каждые \(minutes) мин")
                        .tag(minutes)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
            if let date = viewModel.lastBackupDate {
                Text("бэкап: \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Рекомендация .gitignore: служебные файлы + большие аудиозаписи (по
    /// выбору пользователя — в git аудио пухнет, LFS настраивается вручную).
    @ViewBuilder
    private var gitignoreSection: some View {
        if !viewModel.missingIgnoreEntries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Рекомендуем добавить в .gitignore: "
                     + viewModel.missingIgnoreEntries.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Добавить всё") {
                        viewModel.appendIgnoreEntries(viewModel.missingIgnoreEntries)
                    }
                    if viewModel.missingIgnoreEntries.contains(GitignoreAdvisor.recordings) {
                        Button("Без записей встреч") {
                            viewModel.appendIgnoreEntries(
                                viewModel.missingIgnoreEntries.filter { $0 != GitignoreAdvisor.recordings })
                        }
                        .help("Аудио останется в git — репозиторий будет расти; альтернатива — настроить Git LFS вручную.")
                    }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !viewModel.history.isEmpty {
            Divider()
            Text("История")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.history) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(commit.shortHash)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(commit.subject)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(commit.date.formatted(date: .numeric, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }
}
