// ChatChangesView.swift — вкладка «Изменения» в чате (задача 40).
//
// Отдельная вкладка вместо ленты сообщений (кнопка в нижней панели):
//  1) «В этом чате» — все файловые операции агента с diff'ами (агрегат
//     fileChanges по сообщениям, новые сверху);
//  2) «Git» — состояние рабочего каталога чата: ветка/ahead/behind,
//     незакоммиченный diff по файлам, отличия ветки от main/master и
//     коммит/пуш прямо отсюда (референс UX — Claude Code).
// Чистая логика (разбиение diff'а, агрегация, git-обзор) — в
// ChatChangesModels.swift; здесь только отрисовка и действия.

import SwiftUI

// MARK: - Карточка diff'а одного файла

/// Заголовок (путь + бейдж +N −M) с раскрываемым цветным diff'ом.
/// onRevert — точечный откат этого файла (задача 40); nil — кнопки нет
/// (например, секция закоммиченных отличий от базовой ветки).
struct FileDiffCard: View {
    let title: String
    var subtitle: String?
    var badge: String?
    let diff: String
    var initiallyExpanded = false
    var onRevert: (() -> Void)?

    @State private var isExpanded = false
    @State private var appeared = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            DiffTextView(diff: diff)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(.secondary)
                }
                if let onRevert {
                    Button {
                        onRevert()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Откатить этот файл (tracked — к HEAD, новый — в Корзину)")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.06)))
        .onAppear {
            guard !appeared else { return }
            appeared = true
            isExpanded = initiallyExpanded
        }
    }
}

// MARK: - Панель «Изменения»

struct ChatChangesPanel: View {
    @ObservedObject var viewModel: ChatViewModel
    let onClose: () -> Void

    @State private var overview: GitChangesOverview?
    @State private var isLoading = false
    @State private var refreshTick = 0
    @State private var commitMessage = ""
    @State private var isCommitting = false
    /// Файл, ожидающий подтверждения отката (диалог — откат разрушает
    /// незакоммиченные правки этого файла).
    @State private var revertTarget: String?
    @State private var showsRevertConfirm = false

    private var chat: Chat? { viewModel.selectedChat }
    private var rootOverride: String? { chat?.configuration.projectRootPath }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                agentSection
                Divider()
                gitSection
            }
            .padding()
        }
        .task(id: "\(chat?.id.uuidString ?? "")|\(refreshTick)") {
            await reload()
        }
        // Подтверждение отката: per-file, никаких массовых «откатить всё».
        .confirmationDialog("Откатить файл?",
                            isPresented: $showsRevertConfirm,
                            titleVisibility: .visible,
                            presenting: revertTarget) { path in
            Button("Откатить «\(path)»", role: .destructive) {
                runGitAction {
                    await viewModel.chatGitBridge?.revertFile(rootOverride, path)
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { path in
            Text("Отслеживаемый файл вернётся к последнему коммиту (незакоммиченные правки «\(path)» пропадут), новый файл будет перемещён в Корзину. Другие файлы не затрагиваются.")
        }
    }

    /// Запросить откат файла (кнопка ↩ на карточке/строке).
    private func requestRevert(_ path: String) {
        revertTarget = path
        showsRevertConfirm = true
    }

    private func reload() async {
        isLoading = true
        overview = await viewModel.chatGitBridge?.overview(rootOverride)
        isLoading = false
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 8) {
            Label("Изменения", systemImage: "plusminus.circle")
                .font(.headline)
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                refreshTick += 1
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Перечитать git-состояние каталога")
            Button {
                onClose()
            } label: {
                Label("К диалогу", systemImage: "xmark")
            }
            .controlSize(.small)
            .help("Вернуться к сообщениям чата")
        }
    }

    // MARK: Изменения агента

    private var agentEntries: [AgentChangeEntry] {
        ChatChangesAggregator.agentChanges(messages: chat?.messages ?? [])
    }

    @ViewBuilder
    private var agentSection: some View {
        let entries = agentEntries
        VStack(alignment: .leading, spacing: 8) {
            Text("В этом чате — операции агента (\(entries.count))")
                .font(.subheadline.bold())
            if entries.isEmpty {
                Text("Агент ещё не менял файлы в этом чате. Попросите его создать или обновить файл — каждая операция появится здесь с diff'ом.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                FileDiffCard(
                    title: entry.change.relativePath,
                    subtitle: "\(entry.change.kind.label) · \(entry.messageDate.formatted(date: .abbreviated, time: .shortened))",
                    badge: nil,
                    diff: entry.change.diff,
                    initiallyExpanded: index == 0,
                    onRevert: entry.change.kind == .deleted ? nil : {
                        requestRevert(entry.change.relativePath)
                    })
            }
        }
    }

    // MARK: Git-состояние каталога

    @ViewBuilder
    private var gitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let overview {
                if !overview.isRepo {
                    Text("Git")
                        .font(.subheadline.bold())
                    Text("Рабочий каталог чата — не git-репозиторий: показать diff против веток и закоммитить нечего. Инициализируйте репозиторий (git init) — и здесь появится полный обзор.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    gitOverviewBody(overview)
                }
            } else if !isLoading {
                Text("Git-состояние недоступно (каталог не задан).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func gitOverviewBody(_ overview: GitChangesOverview) -> some View {
        // Шапка: ветка, upstream, ahead/behind.
        HStack(spacing: 8) {
            Label(overview.branch ?? "(ветка не определена)",
                  systemImage: "arrow.triangle.branch")
                .font(.subheadline.bold())
            if let upstream = overview.upstream {
                Text(upstream)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if overview.ahead > 0 {
                Text("↑\(overview.ahead)")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                    .help("Локальных коммитов, которых нет в remote")
            }
            if overview.behind > 0 {
                Text("↓\(overview.behind)")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                    .help("Коммитов в remote, которых нет локально")
            }
            Spacer()
        }

        // Незакоммиченные изменения: diff по файлам + коммит.
        let sections = DiffSplitter.split(overview.diff)
        if overview.files.isEmpty && sections.isEmpty {
            Label("Рабочее дерево чистое — незакоммиченных изменений нет.",
                  systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Text("Незакоммичено (\(overview.files.count) файлов)")
                .font(.subheadline.bold())
            // Файлы без diff-секции (новые/переименованные) — строкой статуса.
            let sectionPaths = Set(sections.map(\.path))
            ForEach(overview.files.filter { !sectionPaths.contains($0.path) }) { file in
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(file.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.kind.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        requestRevert(file.path)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Откатить: tracked — к HEAD, новый — в Корзину")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06)))
            }
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                FileDiffCard(title: section.path,
                             badge: section.badge,
                             diff: section.text,
                             initiallyExpanded: index == 0 && sections.count <= 3,
                             onRevert: { requestRevert(section.path) })
            }
            commitControls
        }

        // Отличия текущей ветки от main/master (закоммиченные).
        if let base = overview.baseBranch, !overview.baseDiff.isEmpty {
            let baseSections = DiffSplitter.split(overview.baseDiff)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(baseSections) { section in
                        FileDiffCard(title: section.path,
                                     badge: section.badge,
                                     diff: section.text)
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("Отличия ветки от \(base) (\(baseSections.count) файлов)",
                      systemImage: "arrow.triangle.merge")
                    .font(.subheadline.bold())
            }
        }

        // Чистое дерево + ahead: остаётся только запушить.
        if overview.files.isEmpty, overview.ahead > 0, overview.upstream != nil {
            Button(isCommitting ? "Отправка…" : "Запушить \(overview.ahead) коммит(а)") {
                runGitAction { await viewModel.chatGitBridge?.push(rootOverride) }
            }
            .disabled(isCommitting)
        }
    }

    /// Поле сообщения + «Закоммитить» (+ пуш при настроенном upstream).
    private var commitControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Сообщение коммита…", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(isCommitting ? "Коммит…" : "Закоммитить") {
                    runGitAction {
                        await viewModel.chatGitBridge?.commit(rootOverride, trimmedMessage)
                    }
                }
                .disabled(trimmedMessage.isEmpty || isCommitting)
                .help("git add -A && git commit в каталоге чата")
                if overview?.upstream != nil {
                    Button("Закоммитить и запушить") {
                        runGitAction {
                            if let error = await viewModel.chatGitBridge?
                                .commit(rootOverride, trimmedMessage) { return error }
                            return await viewModel.chatGitBridge?.push(rootOverride)
                        }
                    }
                    .disabled(trimmedMessage.isEmpty || isCommitting)
                }
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    private var trimmedMessage: String {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Общий раннер git-действий: лок кнопок, баннер об итоге, перечитка.
    private func runGitAction(_ action: @escaping () async -> String?) {
        isCommitting = true
        Task {
            let error = await action()
            isCommitting = false
            if let error {
                viewModel.showNotice("Git: \(error)")
            } else {
                viewModel.showNotice("Git: готово.")
                commitMessage = ""
                refreshTick += 1
            }
        }
    }
}
