// ProjectDocsStatusSection.swift — секция статуса RAG-индекса документации
// проекта во вкладке «Инструменты» (задача 47), по образцу RagStatusSection:
// цифры + модель + дата, кнопка «Перестроить индекс» с прогрессом,
// недоступность (нет репозитория / нет эмбеддера) — причина с переходом на
// нужную вкладку настроек.

import SwiftUI

struct ProjectDocsStatusSection: View {
    let provider: ProjectToolsProvider
    let repoPath: String
    let onOpenSettingsTab: (SettingsTab) -> Void

    @State private var stats: ProjectDocsIndexService.DocsIndexStats?
    @State private var hasEmbedder = false
    @State private var isRebuilding = false
    @State private var lastError: String?

    private var status: ProjectDocsIndexUIStatus {
        .classify(hasRepo: !repoPath.isEmpty, hasEmbedder: hasEmbedder, stats: stats)
    }

    var body: some View {
        Section("Документация проекта") {
            HStack {
                statusText
                Spacer()
                if isRebuilding {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Переиндексация…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Перестроить индекс") { rebuild() }
                        .disabled(status.rebuildDisabled)
                        .help("Сбросить и заново построить RAG-индекс документации репозитория")
                }
            }
            if let reason = status.unavailableReason {
                Button {
                    onOpenSettingsTab(unavailableTab)
                } label: {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
            if let lastError {
                Label(lastError, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .task(id: repoPath) { await refresh() }
    }

    @ViewBuilder
    private var statusText: some View {
        switch status {
        case let .built(line, _):
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notBuilt:
            Text("Индекс не построен")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .noRepo:
            Text("—")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Репозиторий не выбран — вести на «Инструменты» (там же выбор папки);
    /// эмбеддера нет — на «Провайдеры» (ключ) либо «Локальные модели» (Ollama);
    /// как в мастере ассистента проекта (ChatToolingViews) — «Провайдеры».
    private var unavailableTab: SettingsTab {
        repoPath.isEmpty ? .tools : .providers
    }

    private func refresh() async {
        hasEmbedder = provider.hasEmbeddingProvider()
        stats = await provider.docsIndexStats()
    }

    private func rebuild() {
        isRebuilding = true
        lastError = nil
        Task {
            do {
                try await provider.rebuildDocsIndex()
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            stats = await provider.docsIndexStats()
            isRebuilding = false
        }
    }
}
